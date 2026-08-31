; AsmFlow -- synchronous bounded client for the local NDJSON control plane.
;
; This module is linked by asmflow-tui and asmflowctl, never by storage or
; provider code.  It owns only a Unix-domain socket and two bounded buffers.
; A call writes one request, then reads until its matching string id arrives;
; unsolicited event envelopes are consumed and ignored.  The exact correlated
; response bytes (without the terminating LF) are copied to caller-owned output
; so `asmflowctl --json` can reproduce the daemon envelope byte for byte.

        bits 64
        default rel

%include "asmflow.inc"
%include "control.inc"
%include "control_client.inc"
%include "json.inc"
%include "jsonw.inc"
%include "socket.inc"

        extern af_mem_zero
        extern af_mem_copy
        extern af_mem_eq
        extern af_u64_to_dec

        extern af_buf_init
        extern af_buf_free
        extern af_buf_clear
        extern af_buf_append
        extern af_buf_data
        extern af_buf_len

        extern af_jw_init
        extern af_jw_begin_object
        extern af_jw_end_object
        extern af_jw_key
        extern af_jw_member_string_n
        extern af_jw_raw
        extern af_jw_finish

        extern af_json_parse
        extern af_json_doc_root
        extern af_json_doc_free
        extern af_json_type
        extern af_json_get_string
        extern af_json_get_bool
        extern af_json_get_object
        extern af_json_member

        extern af_utf8_validate
        extern af_ctl_frame_next
        extern af_ctl_frame_consume
        extern af_ctl_frame_finish

        extern af_sys_socket
        extern af_sys_connect
        extern af_sys_close
        extern af_sys_read
        extern af_sys_sendto
        extern af_sys_setsockopt
        extern af_status_from_errno

%define MSG_NOSIGNAL 0x4000
%define SO_RCVTIMEO   20
%define SO_SNDTIMEO   21

        section .rodata

ctlc_id_prefix: db "ctl-"
ctlc_id_prefix_len equ $ - ctlc_id_prefix

ctlc_k_id:     db "id", 0
ctlc_k_method: db "method", 0
ctlc_k_params: db "params", 0
ctlc_k_ok:     db "ok", 0
ctlc_k_result: db "result", 0
ctlc_k_error:  db "error", 0
ctlc_k_event:  db "event", 0

        section .text

; ---------------------------------------------------------------------------
; af_ctlc_cstrnlen(const char *s, u64 maximum, u64 *out_len) -> af_status
;
; Reads at most maximum+1 bytes.  AF_E_LIMIT means no terminator occurred at or
; before `maximum`; the output is written only on success.  All pointers are
; BORROWED.
; ---------------------------------------------------------------------------
        global af_ctlc_cstrnlen
af_ctlc_cstrnlen:
        test    rdi, rdi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        xor     eax, eax
.scan:
        cmp     rax, rsi
        ja      .limit
        cmp     byte [rdi + rax], 0
        je      .found
        inc     rax
        jmp     .scan
.found:
        mov     [rdx], rax
        xor     eax, eax
        ret
.limit:
        mov     rax, AF_E_LIMIT
        ret
.invalid:
        mov     rax, AF_E_INVALID
        ret

; ---------------------------------------------------------------------------
; af_ctl_client_init(af_ctl_client *client, const char *socket_path)
;   -> af_status
;
; `client` storage is caller-owned and need not be preinitialised.  The path is
; BORROWED for this call only.  On success the client owns its descriptor and
; embedded buffer payloads; on failure it owns nothing.
; ---------------------------------------------------------------------------
        global af_ctl_client_init
af_ctl_client_init:
        AF_ENTER 160
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi

        mov     rdi, rbx
        mov     rsi, AF_CTLC_SIZE
        call    af_mem_zero
        mov     qword [rbx + AF_CTLC_FD], -1
        mov     qword [rbx + AF_CTLC_NEXT_ID], 1

        lea     rdi, [rbx + AF_CTLC_INBOX]
        mov     rsi, AF_CTL_FRAME_DEFAULT_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rdi, [rbx + AF_CTLC_OUTBOX]
        mov     rsi, AF_CTL_FRAME_DEFAULT_MAX
        call    af_buf_init
        test    rax, rax
        js      .cleanup
        mov     qword [rbx + AF_CTLC_INITIALIZED], 1

        ; sockaddr_un lives at rsp+0.  The counted path length at rsp+120 is
        ; kept separate from the 110-byte packed kernel structure.
        mov     rdi, r12
        mov     rsi, AF_CTLC_PATH_MAX
        lea     rdx, [rsp + 120]
        call    af_ctlc_cstrnlen
        test    rax, rax
        js      .cleanup
        cmp     qword [rsp + 120], 0
        je      .invalid_cleanup

        lea     rdi, [rsp]
        mov     rsi, SUN_SIZE
        call    af_mem_zero
        mov     word [rsp + SUN_FAMILY], AF_UNIX
        lea     rdi, [rsp + SUN_PATH]
        mov     rsi, r12
        mov     rdx, [rsp + 120]
        call    af_mem_copy

        mov     edi, AF_UNIX
        mov     esi, SOCK_STREAM | SOCK_CLOEXEC
        xor     edx, edx
        call    af_sys_socket
        test    rax, rax
        js      .sys_failed_cleanup
        mov     [rbx + AF_CTLC_FD], rax

        ; timeval { seconds, microseconds }. Both directions are bounded so a
        ; peer that accepts and then stops reading or replying cannot wedge the
        ; CLI or prevent the TUI from reaching its terminal-restore path.
        mov     qword [rsp + 128], AF_CTLC_IO_TIMEOUT_SEC
        mov     qword [rsp + 136], 0
        mov     rdi, [rbx + AF_CTLC_FD]
        mov     esi, SOL_SOCKET
        mov     edx, SO_RCVTIMEO
        lea     rcx, [rsp + 128]
        mov     r8d, 16
        call    af_sys_setsockopt
        test    rax, rax
        js      .sys_failed_cleanup
        mov     rdi, [rbx + AF_CTLC_FD]
        mov     esi, SOL_SOCKET
        mov     edx, SO_SNDTIMEO
        lea     rcx, [rsp + 128]
        mov     r8d, 16
        call    af_sys_setsockopt
        test    rax, rax
        js      .sys_failed_cleanup

        mov     rdi, [rbx + AF_CTLC_FD]
        lea     rsi, [rsp]
        mov     rdx, SUN_SIZE
        call    af_sys_connect
        test    rax, rax
        js      .sys_failed_cleanup
        AF_LEAVE_OK

.sys_failed_cleanup:
        mov     rdi, rax
        call    af_status_from_errno
        mov     r12, rax
        mov     rdi, rbx
        call    af_ctl_client_close
        mov     rax, r12
        AF_LEAVE
.invalid_cleanup:
        mov     r12, AF_E_INVALID
        mov     rdi, rbx
        call    af_ctl_client_close
        mov     rax, r12
        AF_LEAVE
.cleanup:
        mov     r12, rax
        mov     rdi, rbx
        call    af_ctl_client_close
        mov     rax, r12
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_ctl_client_close(af_ctl_client *client) -> void
;
; Idempotent.  Releases the descriptor and both owned buffer payloads.
; ---------------------------------------------------------------------------
        global af_ctl_client_close
af_ctl_client_close:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, [rbx + AF_CTLC_FD]
        cmp     rdi, 0
        jl      .no_fd
        call    af_sys_close
.no_fd:
        mov     qword [rbx + AF_CTLC_FD], -1
        lea     rdi, [rbx + AF_CTLC_INBOX]
        call    af_buf_free
        lea     rdi, [rbx + AF_CTLC_OUTBOX]
        call    af_buf_free
        mov     qword [rbx + AF_CTLC_INITIALIZED], 0
        mov     qword [rbx + AF_CTLC_LAST_OK], 0
        mov     qword [rbx + AF_CTLC_ID_LEN], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_client_last_ok(const af_ctl_client *client) -> i64
; ---------------------------------------------------------------------------
        global af_ctl_client_last_ok
af_ctl_client_last_ok:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + AF_CTLC_LAST_OK]
.done:
        ret

; ---------------------------------------------------------------------------
; af_ctl_client_fd(const af_ctl_client *client) -> i64
; ---------------------------------------------------------------------------
        global af_ctl_client_fd
af_ctl_client_fd:
        mov     rax, -1
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + AF_CTLC_FD]
.done:
        ret

; ---------------------------------------------------------------------------
; af_ctlc_validate_params(const char *json, u64 len) -> af_status
;
; A command-line parameter payload must be one bounded JSON object.  Parse
; detail is intentionally not exposed here; an invalid local argument maps to
; AF_E_CTL_PARAMS and never reaches the daemon.
; ---------------------------------------------------------------------------
        global af_ctlc_validate_params
af_ctlc_validate_params:
        AF_ENTER 96
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        cmp     rsi, AF_CTLC_PARAMS_MAX
        ja      .invalid
        mov     rbx, rdi
        mov     r12, rsi

        mov     [rsp + AF_JSONLIM_MAX_BYTES], r12
        mov     qword [rsp + AF_JSONLIM_MAX_DEPTH], AF_CTLC_JSON_DEPTH
        mov     qword [rsp + AF_JSONLIM_MAX_STRING], AF_CTL_FRAME_DEFAULT_MAX
        mov     qword [rsp + AF_JSONLIM_MAX_ELEMS], AF_CTLC_JSON_ELEMENTS
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        test    rax, rax
        js      .invalid
        lea     rdi, [rsp + 32]
        call    af_json_doc_root
        mov     rdi, rax
        call    af_json_type
        mov     r13, rax
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        cmp     r13, AF_JSON_OBJECT
        jne     .invalid
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_CTL_PARAMS

; ---------------------------------------------------------------------------
; af_ctlc_make_id(af_ctl_client *client) -> af_status
; ---------------------------------------------------------------------------
af_ctlc_make_id:
        AF_ENTER 16
        mov     rbx, rdi
        mov     rdi, [rbx + AF_CTLC_NEXT_ID]
        test    rdi, rdi
        jnz     .have_id
        mov     edi, 1
        mov     qword [rbx + AF_CTLC_NEXT_ID], 1
.have_id:
        mov     r12, rdi
        lea     rdi, [rbx + AF_CTLC_ID]
        lea     rsi, [ctlc_id_prefix]
        mov     rdx, ctlc_id_prefix_len
        call    af_mem_copy
        mov     rdi, r12
        lea     rsi, [rbx + AF_CTLC_ID + ctlc_id_prefix_len]
        mov     rdx, AF_CTLC_ID_STORAGE - ctlc_id_prefix_len
        lea     rcx, [rsp]
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     rax, [rsp]
        add     rax, ctlc_id_prefix_len
        mov     [rbx + AF_CTLC_ID_LEN], rax
        inc     r12
        test    r12, r12
        jnz     .store_next
        mov     r12, 1
.store_next:
        mov     [rbx + AF_CTLC_NEXT_ID], r12
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctlc_send_all(i64 fd, const void *bytes, u64 len) -> af_status
;
; Uses MSG_NOSIGNAL, so a daemon disconnect is reported rather than killing the
; client process with SIGPIPE.  The input span is BORROWED.
; ---------------------------------------------------------------------------
af_ctlc_send_all:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
.loop:
        test    r13, r13
        jz      .ok
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        mov     rcx, MSG_NOSIGNAL
        xor     r8d, r8d
        xor     r9d, r9d
        call    af_sys_sendto
        test    rax, rax
        js      .failed
        jz      .pipe
        add     r12, rax
        sub     r13, rax
        jmp     .loop
.failed:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_INTR
        je      .loop
        AF_LEAVE
.pipe:
        AF_LEAVE_ERR AF_E_PIPE
.ok:
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; af_ctlc_read_more(af_ctl_client *client) -> af_status
; ---------------------------------------------------------------------------
af_ctlc_read_more:
        AF_ENTER AF_CTLC_READ_CHUNK
        mov     rbx, rdi
.again:
        mov     rdi, [rbx + AF_CTLC_FD]
        lea     rsi, [rsp]
        mov     rdx, AF_CTLC_READ_CHUNK
        call    af_sys_read
        test    rax, rax
        js      .failed
        jz      .eof
        mov     rdx, rax
        lea     rdi, [rbx + AF_CTLC_INBOX]
        lea     rsi, [rsp]
        call    af_buf_append
        AF_LEAVE
.failed:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_INTR
        je      .again
        AF_LEAVE
.eof:
        AF_LEAVE_ERR AF_E_EOF

; ---------------------------------------------------------------------------
; af_ctlc_next_response(af_ctl_client *client, af_buffer *out_frame)
;   -> af_status
;
; The exact response span is copied before the inbox is consumed.  Parsed JSON
; nodes only borrow their own Jansson allocation and are released on every
; path.  Event envelopes have no id and are bounded to at most 1024 skipped
; frames per request so a peer cannot starve correlation forever with events.
; ---------------------------------------------------------------------------
af_ctlc_next_response:
        AF_ENTER 176
        mov     rbx, rdi
        mov     r12, rsi
        xor     r15d, r15d

.next_frame:
        lea     rdi, [rbx + AF_CTLC_INBOX]
        mov     rsi, AF_CTL_FRAME_DEFAULT_MAX
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_frame_next
        cmp     rax, AF_E_AGAIN
        je      .read_more
        test    rax, rax
        js      .done

        mov     rax, [rsp + 8]
        mov     [rsp + 48 + AF_JSONLIM_MAX_BYTES], rax
        mov     qword [rsp + 48 + AF_JSONLIM_MAX_DEPTH], AF_CTLC_JSON_DEPTH
        mov     qword [rsp + 48 + AF_JSONLIM_MAX_STRING], AF_CTL_FRAME_DEFAULT_MAX
        mov     qword [rsp + 48 + AF_JSONLIM_MAX_ELEMS], AF_CTLC_JSON_ELEMENTS
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [rsp + 48]
        lea     rcx, [rsp + 80]
        call    af_json_parse
        test    rax, rax
        js      .protocol
        lea     rdi, [rsp + 80]
        call    af_json_doc_root
        mov     [rsp + 16], rax
        mov     rdi, rax
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .free_protocol

        mov     rdi, [rsp + 16]
        lea     rsi, [ctlc_k_id]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_string
        test    rax, rax
        jns     .response
        cmp     rax, AF_E_NOTFOUND
        jne     .free_protocol

        ; A frame without an id is ignored only when it is a valid event
        ; envelope.  Other id-less objects are protocol failures.
        mov     rdi, [rsp + 16]
        lea     rsi, [ctlc_k_event]
        xor     edx, edx
        xor     ecx, ecx
        call    af_json_get_string
        test    rax, rax
        js      .free_protocol
        lea     rdi, [rsp + 80]
        call    af_json_doc_free
        lea     rdi, [rbx + AF_CTLC_INBOX]
        mov     rsi, [rsp + 8]
        call    af_ctl_frame_consume
        test    rax, rax
        js      .done
        inc     r15
        cmp     r15, AF_CTLC_EVENT_SKIP_MAX
        ja      .event_limit
        jmp     .next_frame

.response:
        mov     rax, [rsp + 32]
        cmp     rax, [rbx + AF_CTLC_ID_LEN]
        jne     .free_protocol
        mov     rdi, [rsp + 24]
        lea     rsi, [rbx + AF_CTLC_ID]
        mov     rdx, [rsp + 32]
        call    af_mem_eq
        test    rax, rax
        jz      .free_protocol

        mov     rdi, [rsp + 16]
        lea     rsi, [ctlc_k_ok]
        lea     rdx, [rsp + 40]
        call    af_json_get_bool
        test    rax, rax
        js      .free_protocol
        cmp     qword [rsp + 40], 0
        je      .need_error
        mov     rdi, [rsp + 16]
        lea     rsi, [ctlc_k_result]
        xor     edx, edx
        call    af_json_member
        test    rax, rax
        js      .free_protocol
        jmp     .validated
.need_error:
        mov     rdi, [rsp + 16]
        lea     rsi, [ctlc_k_error]
        xor     edx, edx
        call    af_json_get_object
        test    rax, rax
        js      .free_protocol
.validated:
        mov     rax, [rsp + 40]
        mov     [rbx + AF_CTLC_LAST_OK], rax
        mov     rdi, r12
        call    af_buf_clear
        mov     rdi, r12
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_buf_append
        mov     r13, rax
        lea     rdi, [rsp + 80]
        call    af_json_doc_free
        test    r13, r13
        js      .return_saved
        lea     rdi, [rbx + AF_CTLC_INBOX]
        mov     rsi, [rsp + 8]
        call    af_ctl_frame_consume
        AF_LEAVE

.read_more:
        mov     rdi, rbx
        call    af_ctlc_read_more
        test    rax, rax
        js      .done
        jmp     .next_frame
.free_protocol:
        lea     rdi, [rsp + 80]
        call    af_json_doc_free
.protocol:
        mov     rax, AF_E_INVALID
.done:
        AF_LEAVE
.return_saved:
        mov     rax, r13
        AF_LEAVE
.event_limit:
        AF_LEAVE_ERR AF_E_LIMIT

; ---------------------------------------------------------------------------
; af_ctl_client_call(af_ctl_client *client,
;                    const char *method, u64 method_len,
;                    const char *params_or_null, u64 params_len,
;                    af_buffer *out_frame) -> af_status
;
; The method and params spans are BORROWED.  `out_frame` is caller-owned and is
; replaced with the exact correlated envelope on success, whether that envelope
; has ok=true or ok=false.  Inspect `af_ctl_client_last_ok` after AF_OK.
; ---------------------------------------------------------------------------
        global af_ctl_client_call
af_ctl_client_call:
        AF_ENTER 128
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8
        mov     [rsp], r9

        test    rbx, rbx
        jz      .invalid
        cmp     qword [rbx + AF_CTLC_INITIALIZED], 1
        jne     .closed
        cmp     qword [rbx + AF_CTLC_FD], 0
        jl      .closed
        test    r12, r12
        jz      .bad_params
        test    r13, r13
        jz      .bad_params
        cmp     r13, AF_CTLC_METHOD_MAX
        ja      .bad_params
        cmp     qword [rsp], 0
        je      .invalid
        mov     rdi, r12
        mov     rsi, r13
        call    af_utf8_validate
        test    rax, rax
        jz      .bad_params

        test    r14, r14
        jz      .no_params
        mov     rdi, r14
        mov     rsi, r15
        call    af_ctlc_validate_params
        test    rax, rax
        js      .done
        jmp     .params_valid
.no_params:
        test    r15, r15
        jnz     .bad_params
.params_valid:
        mov     qword [rbx + AF_CTLC_LAST_OK], 0
        mov     rdi, [rsp]
        call    af_buf_clear
        lea     rdi, [rbx + AF_CTLC_OUTBOX]
        call    af_buf_clear
        mov     rdi, rbx
        call    af_ctlc_make_id
        test    rax, rax
        js      .done

        ; The writer occupies rsp+16..rsp+79.  Its sticky status lets the
        ; sequence remain linear; af_jw_finish reports the first failed append.
        lea     rdi, [rsp + 16]
        lea     rsi, [rbx + AF_CTLC_OUTBOX]
        call    af_jw_init
        lea     rdi, [rsp + 16]
        call    af_jw_begin_object
        lea     rdi, [rsp + 16]
        lea     rsi, [ctlc_k_id]
        lea     rdx, [rbx + AF_CTLC_ID]
        mov     rcx, [rbx + AF_CTLC_ID_LEN]
        call    af_jw_member_string_n
        lea     rdi, [rsp + 16]
        lea     rsi, [ctlc_k_method]
        mov     rdx, r12
        mov     rcx, r13
        call    af_jw_member_string_n
        test    r14, r14
        jz      .request_close
        lea     rdi, [rsp + 16]
        lea     rsi, [ctlc_k_params]
        call    af_jw_key
        lea     rdi, [rsp + 16]
        mov     rsi, r14
        mov     rdx, r15
        call    af_jw_raw
.request_close:
        lea     rdi, [rsp + 16]
        call    af_jw_end_object
        lea     rdi, [rsp + 16]
        call    af_jw_finish
        test    rax, rax
        js      .done
        lea     rdi, [rbx + AF_CTLC_OUTBOX]
        xor     esi, esi
        mov     rdx, AF_CTL_FRAME_DEFAULT_MAX
        call    af_ctl_frame_finish
        test    rax, rax
        js      .done

        lea     rdi, [rbx + AF_CTLC_OUTBOX]
        call    af_buf_data
        mov     [rsp + 88], rax
        lea     rdi, [rbx + AF_CTLC_OUTBOX]
        call    af_buf_len
        mov     rdx, rax
        mov     rdi, [rbx + AF_CTLC_FD]
        mov     rsi, [rsp + 88]
        call    af_ctlc_send_all
        test    rax, rax
        js      .done

        mov     rdi, rbx
        mov     rsi, [rsp]
        call    af_ctlc_next_response
.done:
        AF_LEAVE
.bad_params:
        AF_LEAVE_ERR AF_E_CTL_PARAMS
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
