; AsmFlow -- asmflowctl command execution.
;
; All policy remains in NASM: path selection, argument bounds, request
; construction, response correlation, output mode, and exit status.  libc is
; used only for getenv's ABI; the returned pointer is STATIC process
; environment storage and is never retained after this call.

        bits 64
        default rel

%include "asmflow.inc"
%include "control.inc"
%include "control_client.inc"

        extern getenv

        extern af_mem_zero
        extern af_buf_init
        extern af_buf_free
        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_append_u64
        extern af_buf_data
        extern af_buf_len
        extern af_utf8_validate
        extern af_write_all
        extern af_sys_getuid

        extern af_ctlc_cstrnlen
        extern af_ctlc_validate_params
        extern af_ctl_client_init
        extern af_ctl_client_close
        extern af_ctl_client_call
        extern af_ctl_client_last_ok
        extern af_ctl_table_response

%define CTLR_CLIENT       0
%define CTLR_PATH_BUF     (CTLR_CLIENT + AF_CTLC_SIZE)
%define CTLR_RESPONSE_BUF (CTLR_PATH_BUF + 32)
%define CTLR_METHOD_LEN   (CTLR_RESPONSE_BUF + 32)
%define CTLR_PARAMS_LEN   (CTLR_METHOD_LEN + 8)
%define CTLR_PATH_PTR     (CTLR_PARAMS_LEN + 8)
%define CTLR_PATH_LEN     (CTLR_PATH_PTR + 8)
%define CTLR_EXIT_CODE    (CTLR_PATH_LEN + 8)
%define CTLR_STATUS       (CTLR_EXIT_CODE + 8)
%define CTLR_LOCAL_SIZE   (CTLR_STATUS + 8)

        section .rodata

ctlr_env_xdg: db "XDG_RUNTIME_DIR", 0
ctlr_path_prefix: db "/run/user/"
ctlr_path_prefix_len equ $ - ctlr_path_prefix
ctlr_path_suffix: db "/asmflow/control.sock"
ctlr_path_suffix_len equ $ - ctlr_path_suffix
ctlr_path_suffix_no_slash: db "asmflow/control.sock"
ctlr_path_suffix_no_slash_len equ $ - ctlr_path_suffix_no_slash
ctlr_lf: db 10

ctlr_err_usage:
        db "asmflowctl: METHOD must be valid UTF-8 and PARAMS_JSON must be a bounded JSON object.", 10
        db "Usage: asmflowctl [--socket PATH] [--json|--table] METHOD [PARAMS_JSON]", 10
ctlr_err_usage_len equ $ - ctlr_err_usage
ctlr_usage_hint:
        db "Usage: asmflowctl [--socket PATH] [--json|--table] METHOD [PARAMS_JSON]", 10
ctlr_usage_hint_len equ $ - ctlr_usage_hint
ctlr_err_path:
        db "asmflowctl: the control socket path is invalid or too long.", 10
ctlr_err_path_len equ $ - ctlr_err_path
ctlr_err_connect:
        db "asmflowctl: could not connect to the daemon control socket.", 10
ctlr_err_connect_len equ $ - ctlr_err_connect
ctlr_err_protocol:
        db "asmflowctl: the daemon returned an invalid control response.", 10
ctlr_err_protocol_len equ $ - ctlr_err_protocol
ctlr_err_output:
        db "asmflowctl: could not write command output.", 10
ctlr_err_output_len equ $ - ctlr_err_output

        section .text

; ---------------------------------------------------------------------------
; af_ctlr_stderr(const void *text, u64 len) -> void
; ---------------------------------------------------------------------------
af_ctlr_stderr:
        AF_ENTER 0
        mov     rdx, rsi
        mov     rsi, rdi
        mov     edi, 2
        call    af_write_all
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctlr_build_default_path(af_buffer *out) -> af_status
;
; `${XDG_RUNTIME_DIR}/asmflow/control.sock`, falling back to
; `/run/user/<uid>/asmflow/control.sock`.  The output is NUL-terminated and
; owned by `out`; callers borrow its data until the next append/free.
; ---------------------------------------------------------------------------
af_ctlr_build_default_path:
        AF_ENTER 32
        mov     rbx, rdi
        lea     rdi, [ctlr_env_xdg]
        AF_CCALL getenv
        mov     r12, rax
        test    r12, r12
        jz      .fallback
        cmp     byte [r12], '/'
        jne     .fallback
        mov     rdi, r12
        mov     rsi, AF_CTLC_PATH_MAX
        lea     rdx, [rsp]
        call    af_ctlc_cstrnlen
        test    rax, rax
        js      .path_error
        cmp     qword [rsp], 0
        je      .fallback
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, [rsp]
        call    af_buf_append
        test    rax, rax
        js      .done
        mov     rcx, [rsp]
        cmp     byte [r12 + rcx - 1], '/'
        je      .suffix_without_slash
        mov     rdi, rbx
        lea     rsi, [ctlr_path_suffix]
        mov     rdx, ctlr_path_suffix_len
        call    af_buf_append
        jmp     .terminate
.suffix_without_slash:
        mov     rdi, rbx
        lea     rsi, [ctlr_path_suffix_no_slash]
        mov     rdx, ctlr_path_suffix_no_slash_len
        call    af_buf_append
        jmp     .terminate

.fallback:
        mov     rdi, rbx
        lea     rsi, [ctlr_path_prefix]
        mov     rdx, ctlr_path_prefix_len
        call    af_buf_append
        test    rax, rax
        js      .done
        call    af_sys_getuid
        mov     rsi, rax
        mov     rdi, rbx
        call    af_buf_append_u64
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [ctlr_path_suffix]
        mov     rdx, ctlr_path_suffix_len
        call    af_buf_append
.terminate:
        test    rax, rax
        js      .done
        mov     rdi, rbx
        xor     esi, esi
        call    af_buf_append_byte
.done:
        AF_LEAVE
.path_error:
        AF_LEAVE_ERR AF_E_CFG_PATH

; ---------------------------------------------------------------------------
; af_ctl_cli_run(const char *socket_path_or_null, u64 mode,
;                const char *method, const char *params_json_or_null)
;   -> process exit code
;
; Every argument is BORROWED from argv.  The function owns all temporary
; buffers and the control client and releases them through one cleanup path.
; ---------------------------------------------------------------------------
        global af_ctl_cli_run
af_ctl_cli_run:
        AF_ENTER CTLR_LOCAL_SIZE
        mov     rbx, rdi                ; explicit socket, optional
        mov     r12, rsi                ; mode
        mov     r13, rdx                ; method
        mov     r14, rcx                ; params, optional

        lea     rdi, [rsp]
        mov     rsi, CTLR_LOCAL_SIZE
        call    af_mem_zero
        mov     qword [rsp + CTLR_CLIENT + AF_CTLC_FD], -1
        mov     qword [rsp + CTLR_EXIT_CODE], AF_EXIT_FAILURE

        cmp     r12, AF_CTL_MODE_TABLE
        je      .mode_ok
        cmp     r12, AF_CTL_MODE_JSON
        jne     .usage
.mode_ok:
        test    r13, r13
        jz      .usage
        mov     rdi, r13
        mov     rsi, AF_CTLC_METHOD_MAX
        lea     rdx, [rsp + CTLR_METHOD_LEN]
        call    af_ctlc_cstrnlen
        test    rax, rax
        js      .usage
        cmp     qword [rsp + CTLR_METHOD_LEN], 0
        je      .usage
        mov     rdi, r13
        mov     rsi, [rsp + CTLR_METHOD_LEN]
        call    af_utf8_validate
        test    rax, rax
        jz      .usage

        test    r14, r14
        jz      .params_ready
        mov     rdi, r14
        mov     rsi, AF_CTLC_PARAMS_MAX
        lea     rdx, [rsp + CTLR_PARAMS_LEN]
        call    af_ctlc_cstrnlen
        test    rax, rax
        js      .usage
        cmp     qword [rsp + CTLR_PARAMS_LEN], 0
        je      .usage
        ; Local argv validation is deliberately complete before path
        ; resolution or connect.  A usage error must never contact a daemon.
        mov     rdi, r14
        mov     rsi, [rsp + CTLR_PARAMS_LEN]
        call    af_ctlc_validate_params
        test    rax, rax
        js      .usage
.params_ready:

        test    rbx, rbx
        jz      .default_path
        mov     rdi, rbx
        mov     rsi, AF_CTLC_PATH_MAX
        lea     rdx, [rsp + CTLR_PATH_LEN]
        call    af_ctlc_cstrnlen
        test    rax, rax
        js      .path_error
        cmp     qword [rsp + CTLR_PATH_LEN], 0
        je      .path_error
        mov     [rsp + CTLR_PATH_PTR], rbx
        jmp     .path_ready

.default_path:
        lea     rdi, [rsp + CTLR_PATH_BUF]
        mov     rsi, AF_CTLC_PATH_MAX + 1
        call    af_buf_init
        test    rax, rax
        js      .path_error
        lea     rdi, [rsp + CTLR_PATH_BUF]
        call    af_ctlr_build_default_path
        test    rax, rax
        js      .path_error
        lea     rdi, [rsp + CTLR_PATH_BUF]
        call    af_buf_data
        mov     [rsp + CTLR_PATH_PTR], rax
.path_ready:

        lea     rdi, [rsp + CTLR_RESPONSE_BUF]
        mov     rsi, AF_CTL_FRAME_DEFAULT_MAX
        call    af_buf_init
        test    rax, rax
        js      .protocol_error

        lea     rdi, [rsp + CTLR_CLIENT]
        mov     rsi, [rsp + CTLR_PATH_PTR]
        call    af_ctl_client_init
        test    rax, rax
        js      .connect_error

        lea     rdi, [rsp + CTLR_CLIENT]
        mov     rsi, r13
        mov     rdx, [rsp + CTLR_METHOD_LEN]
        mov     rcx, r14
        mov     r8, [rsp + CTLR_PARAMS_LEN]
        lea     r9, [rsp + CTLR_RESPONSE_BUF]
        call    af_ctl_client_call
        test    rax, rax
        js      .call_failed

        cmp     r12, AF_CTL_MODE_JSON
        jne     .table_output
        lea     rdi, [rsp + CTLR_RESPONSE_BUF]
        call    af_buf_data
        mov     r15, rax
        lea     rdi, [rsp + CTLR_RESPONSE_BUF]
        call    af_buf_len
        mov     rdx, rax
        mov     edi, 1
        mov     rsi, r15
        call    af_write_all
        test    rax, rax
        js      .output_error
        mov     edi, 1
        lea     rsi, [ctlr_lf]
        mov     rdx, 1
        call    af_write_all
        test    rax, rax
        js      .output_error
        jmp     .choose_exit

.table_output:
        lea     rdi, [rsp + CTLR_RESPONSE_BUF]
        call    af_buf_data
        mov     r15, rax
        lea     rdi, [rsp + CTLR_RESPONSE_BUF]
        call    af_buf_len
        mov     rsi, rax
        mov     rdi, r15
        mov     rdx, r13
        mov     rcx, [rsp + CTLR_METHOD_LEN]
        mov     r8, 1
        call    af_ctl_table_response
        test    rax, rax
        js      .output_error

.choose_exit:
        lea     rdi, [rsp + CTLR_CLIENT]
        call    af_ctl_client_last_ok
        test    rax, rax
        jz      .daemon_error
        mov     qword [rsp + CTLR_EXIT_CODE], AF_EXIT_OK
        jmp     .cleanup
.daemon_error:
        mov     qword [rsp + CTLR_EXIT_CODE], AF_EXIT_FAILURE
        jmp     .cleanup

.call_failed:
        cmp     rax, AF_E_CTL_PARAMS
        je      .usage
        jmp     .protocol_error
.usage:
        lea     rdi, [ctlr_err_usage]
        mov     rsi, ctlr_err_usage_len
        call    af_ctlr_stderr
        mov     qword [rsp + CTLR_EXIT_CODE], AF_EXIT_USAGE
        jmp     .cleanup
.path_error:
        lea     rdi, [ctlr_err_path]
        mov     rsi, ctlr_err_path_len
        call    af_ctlr_stderr
        lea     rdi, [ctlr_usage_hint]
        mov     rsi, ctlr_usage_hint_len
        call    af_ctlr_stderr
        mov     qword [rsp + CTLR_EXIT_CODE], AF_EXIT_USAGE
        jmp     .cleanup
.connect_error:
        lea     rdi, [ctlr_err_connect]
        mov     rsi, ctlr_err_connect_len
        call    af_ctlr_stderr
        mov     qword [rsp + CTLR_EXIT_CODE], AF_EXIT_FAILURE
        jmp     .cleanup
.protocol_error:
        lea     rdi, [ctlr_err_protocol]
        mov     rsi, ctlr_err_protocol_len
        call    af_ctlr_stderr
        mov     qword [rsp + CTLR_EXIT_CODE], AF_EXIT_FAILURE
        jmp     .cleanup
.output_error:
        lea     rdi, [ctlr_err_output]
        mov     rsi, ctlr_err_output_len
        call    af_ctlr_stderr
        mov     qword [rsp + CTLR_EXIT_CODE], AF_EXIT_FAILURE

.cleanup:
        lea     rdi, [rsp + CTLR_CLIENT]
        call    af_ctl_client_close
        lea     rdi, [rsp + CTLR_PATH_BUF]
        call    af_buf_free
        lea     rdi, [rsp + CTLR_RESPONSE_BUF]
        call    af_buf_free
        mov     rax, [rsp + CTLR_EXIT_CODE]
        AF_LEAVE
