; AsmFlow — configuration rejection reporting.
;
; A rejected configuration has to tell the operator three things: what rule was
; broken, where, and nothing else. "Where" is an RFC 6901 JSON Pointer built
; incrementally as the validator descends, so a failure deep inside
; `/mcp_servers/2/env/FILESYSTEM_TOKEN` names that exact location instead of
; saying "invalid configuration".
;
; The message names the rule, never the value. A configuration file contains
; hostnames, paths, and environment-variable names the operator may not want in
; a log line, and a rejection is one of the few paths that reaches a log before
; redaction policy is even loaded (SECURITY_MODEL.md 16).

        bits 64
        default rel

%include "asmflow.inc"
%include "config.inc"

        extern af_buf_init
        extern af_buf_free
        extern af_buf_clear
        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_append_cstr
        extern af_buf_append_u64
        extern af_buf_data
        extern af_buf_len
        extern af_cstr_len

%define CFGERR_POINTER_MAX 4096
%define CFGERR_MESSAGE_MAX 512

        section .text

; ---------------------------------------------------------------------------
; af_cfg_err_init(af_cfg_error *err) -> af_status
;
; Ownership: `err` is caller-supplied storage. af_cfg_err_free releases the two
; buffers it owns.
; ---------------------------------------------------------------------------
        global af_cfg_err_init
af_cfg_err_init:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     qword [rbx + CFGERR_CODE], AF_OK
        lea     rdi, [rbx + CFGERR_POINTER]
        mov     rsi, CFGERR_POINTER_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rdi, [rbx + CFGERR_MESSAGE]
        mov     rsi, CFGERR_MESSAGE_MAX
        call    af_buf_init
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_cfg_err_free(af_cfg_error *err) -> void
; ---------------------------------------------------------------------------
        global af_cfg_err_free
af_cfg_err_free:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        lea     rdi, [rbx + CFGERR_POINTER]
        call    af_buf_free
        lea     rdi, [rbx + CFGERR_MESSAGE]
        call    af_buf_free
        mov     qword [rbx + CFGERR_CODE], AF_OK
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_err_reset(af_cfg_error *err) -> void
;
; Clears the code, the pointer, and the message while keeping the allocations,
; so a reload attempt starts from a clean slate without another malloc.
; ---------------------------------------------------------------------------
        global af_cfg_err_reset
af_cfg_err_reset:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     qword [rbx + CFGERR_CODE], AF_OK
        lea     rdi, [rbx + CFGERR_POINTER]
        call    af_buf_clear
        lea     rdi, [rbx + CFGERR_MESSAGE]
        call    af_buf_clear
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_err_push_key(af_cfg_error *err, const char *key) -> af_status
;
; Appends "/key" with the RFC 6901 escapes: '~' becomes "~0" and '/' becomes
; "~1". Configuration keys are plain identifiers today, but the pointer also
; carries operator-chosen names such as environment variables and object keys
; from `mcp_servers[].env`, so the escaping is not decorative.
; ---------------------------------------------------------------------------
        global af_cfg_err_push_key
af_cfg_err_push_key:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi                ; key
        lea     r13, [rbx + CFGERR_POINTER]

        mov     rdi, r13
        mov     rsi, '/'
        call    af_buf_append_byte
        test    rax, rax
        js      .done

        xor     r14, r14                ; cursor
.loop:
        movzx   eax, byte [r12 + r14]
        test    al, al
        jz      .ok
        cmp     al, '~'
        je      .tilde
        cmp     al, '/'
        je      .slash
        mov     rdi, r13
        movzx   esi, al
        call    af_buf_append_byte
        test    rax, rax
        js      .done
        inc     r14
        jmp     .loop
.tilde:
        mov     rdi, r13
        lea     rsi, [esc_tilde]
        mov     rdx, 2
        call    af_buf_append
        test    rax, rax
        js      .done
        inc     r14
        jmp     .loop
.slash:
        mov     rdi, r13
        lea     rsi, [esc_slash]
        mov     rdx, 2
        call    af_buf_append
        test    rax, rax
        js      .done
        inc     r14
        jmp     .loop
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_cfg_err_push_index(af_cfg_error *err, u64 index) -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_err_push_index
af_cfg_err_push_index:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        lea     r13, [rbx + CFGERR_POINTER]
        mov     rdi, r13
        mov     rsi, '/'
        call    af_buf_append_byte
        test    rax, rax
        js      .done
        mov     rdi, r13
        mov     rsi, r12
        call    af_buf_append_u64
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_cfg_err_truncate(af_cfg_error *err, u64 length) -> af_status
;
; Restores the pointer to a previously recorded length. The validator records
; af_cfg_err_depth() before descending and truncates back to it afterwards,
; which is cheaper and less error-prone than parsing the pointer to remove a
; trailing segment.
; ---------------------------------------------------------------------------
        global af_cfg_err_truncate
af_cfg_err_truncate:
        test    rdi, rdi
        jz      .invalid
        mov     rax, [rdi + CFGERR_POINTER + 8]     ; current length
        cmp     rsi, rax
        ja      .range
        mov     [rdi + CFGERR_POINTER + 8], rsi
        xor     eax, eax
        ret
.range:
        mov     rax, AF_E_RANGE
        ret
.invalid:
        mov     rax, AF_E_INVALID
        ret

; ---------------------------------------------------------------------------
; af_cfg_err_depth(const af_cfg_error *err) -> u64
;
; The current pointer length, for pairing with af_cfg_err_truncate.
; ---------------------------------------------------------------------------
        global af_cfg_err_depth
af_cfg_err_depth:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CFGERR_POINTER + 8]
.done:
        ret

; ---------------------------------------------------------------------------
; af_cfg_err_fail(af_cfg_error *err, i64 code, const char *message)
;   -> af_status (always `code`, so a caller can tail-return it)
;
; The first failure wins. A later rule that also trips on the same document
; must not overwrite the pointer that named the original cause.
; ---------------------------------------------------------------------------
        global af_cfg_err_fail
af_cfg_err_fail:
        AF_ENTER 16
        test    rdi, rdi
        jz      .no_error_object
        mov     rbx, rdi
        mov     r12, rsi                ; code
        mov     r13, rdx                ; message

        cmp     qword [rbx + CFGERR_CODE], AF_OK
        jne     .already_failed

        mov     [rbx + CFGERR_CODE], r12
        lea     rdi, [rbx + CFGERR_MESSAGE]
        mov     rsi, r13
        call    af_buf_append_cstr
.already_failed:
        mov     rax, r12
        AF_LEAVE
.no_error_object:
        mov     rax, rsi
        AF_LEAVE

; ---------------------------------------------------------------------------
; Accessors for tests and the control plane.
;
; af_cfg_err_code(err) -> af_status
; af_cfg_err_pointer(err) -> const char * (BORROWED, not NUL-terminated)
; af_cfg_err_pointer_len(err) -> u64
; af_cfg_err_message(err) -> const char * (BORROWED, not NUL-terminated)
; af_cfg_err_message_len(err) -> u64
; ---------------------------------------------------------------------------
        global af_cfg_err_code
af_cfg_err_code:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CFGERR_CODE]
.done:
        ret

        global af_cfg_err_pointer
af_cfg_err_pointer:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CFGERR_POINTER]
.done:
        ret

        global af_cfg_err_pointer_len
af_cfg_err_pointer_len:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CFGERR_POINTER + 8]
.done:
        ret

        global af_cfg_err_message
af_cfg_err_message:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CFGERR_MESSAGE]
.done:
        ret

        global af_cfg_err_message_len
af_cfg_err_message_len:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CFGERR_MESSAGE + 8]
.done:
        ret

        section .rodata
esc_tilde: db "~0"
esc_slash: db "~1"
