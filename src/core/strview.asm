; AsmFlow — borrowed string views.
;
; A string view is {pointer, length} over memory the view does not own. Views
; are how parsed values move between modules without copying: an HTTP header
; name, a JSON string, a config field, an SSE event name. Because a view never
; owns its bytes, every API that stores one documents the lifetime of the
; underlying buffer, and a view is never retained past the arena or buffer it
; points into.
;
; Layout:
;   +0  ptr
;   +8  len
;
; Views are always passed by pointer rather than returned in rax:rdx. Returning
; a two-register struct is valid System V, but it makes the ownership comment
; that has to accompany every view harder to place, and the runtime has no hot
; path where the extra store matters.

        bits 64
        default rel

%include "asmflow.inc"

        extern af_cstr_len
        extern af_mem_eq
        extern af_mem_eq_ci
        extern af_dec_to_u64

%define SV_PTR 0
%define SV_LEN 8
%define SV_SIZE 16

        section .text

; ---------------------------------------------------------------------------
; af_sv_set(af_strview *v, const void *p, u64 n) -> void
; ---------------------------------------------------------------------------
        global af_sv_set
af_sv_set:
        mov     [rdi + SV_PTR], rsi
        mov     [rdi + SV_LEN], rdx
        ret

; ---------------------------------------------------------------------------
; af_sv_from_cstr(af_strview *v, const char *s) -> void
; ---------------------------------------------------------------------------
        global af_sv_from_cstr
af_sv_from_cstr:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rsi
        call    af_cstr_len
        mov     [rbx + SV_PTR], r12
        mov     [rbx + SV_LEN], rax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_sv_eq(const af_strview *a, const af_strview *b) -> i64 (1 = equal)
; ---------------------------------------------------------------------------
        global af_sv_eq
af_sv_eq:
        AF_ENTER 0
        mov     rax, [rdi + SV_LEN]
        cmp     rax, [rsi + SV_LEN]
        jne     .differ
        mov     rdx, rax
        mov     rax, [rdi + SV_PTR]
        mov     rcx, [rsi + SV_PTR]
        mov     rdi, rax
        mov     rsi, rcx
        call    af_mem_eq
        AF_LEAVE
.differ:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_sv_eq_ci(const af_strview *a, const af_strview *b) -> i64 (1 = equal)
;
; ASCII case-insensitive; used for HTTP header names and the redaction registry.
; ---------------------------------------------------------------------------
        global af_sv_eq_ci
af_sv_eq_ci:
        AF_ENTER 0
        mov     rax, [rdi + SV_LEN]
        cmp     rax, [rsi + SV_LEN]
        jne     .differ
        mov     rdx, rax
        mov     rax, [rdi + SV_PTR]
        mov     rcx, [rsi + SV_PTR]
        mov     rdi, rax
        mov     rsi, rcx
        call    af_mem_eq_ci
        AF_LEAVE
.differ:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_sv_eq_cstr(const af_strview *v, const char *s) -> i64 (1 = equal)
; ---------------------------------------------------------------------------
        global af_sv_eq_cstr
af_sv_eq_cstr:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rsi
        call    af_cstr_len
        cmp     rax, [rbx + SV_LEN]
        jne     .differ
        mov     rdx, rax
        mov     rdi, [rbx + SV_PTR]
        mov     rsi, r12
        call    af_mem_eq
        AF_LEAVE
.differ:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_sv_starts_with_cstr(const af_strview *v, const char *prefix) -> i64
; ---------------------------------------------------------------------------
        global af_sv_starts_with_cstr
af_sv_starts_with_cstr:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rsi
        call    af_cstr_len
        cmp     rax, [rbx + SV_LEN]
        ja      .no
        mov     rdx, rax
        mov     rdi, [rbx + SV_PTR]
        mov     rsi, r12
        call    af_mem_eq
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_sv_trim_ascii_ws(af_strview *v) -> void
;
; Trims spaces and horizontal tabs from both ends in place. Deliberately does
; not trim CR or LF: HTTP framing treats those as structure, and silently
; swallowing them would hide a malformed message.
; ---------------------------------------------------------------------------
        global af_sv_trim_ascii_ws
af_sv_trim_ascii_ws:
        mov     rax, [rdi + SV_PTR]
        mov     rcx, [rdi + SV_LEN]
.leading:
        test    rcx, rcx
        jz      .store
        mov     dl, [rax]
        cmp     dl, ' '
        je      .drop_leading
        cmp     dl, 9
        jne     .trailing
.drop_leading:
        inc     rax
        dec     rcx
        jmp     .leading
.trailing:
        test    rcx, rcx
        jz      .store
        mov     dl, [rax + rcx - 1]
        cmp     dl, ' '
        je      .drop_trailing
        cmp     dl, 9
        jne     .store
.drop_trailing:
        dec     rcx
        jmp     .trailing
.store:
        mov     [rdi + SV_PTR], rax
        mov     [rdi + SV_LEN], rcx
        ret

; ---------------------------------------------------------------------------
; af_sv_find_byte(const af_strview *v, u8 c, u64 *out_index) -> af_status
;
; AF_E_NOTFOUND when the byte does not occur.
; ---------------------------------------------------------------------------
        global af_sv_find_byte
af_sv_find_byte:
        mov     r8, [rdi + SV_PTR]
        mov     r9, [rdi + SV_LEN]
        xor     ecx, ecx
.loop:
        cmp     rcx, r9
        jae     .notfound
        cmp     byte [r8 + rcx], sil
        je      .found
        inc     rcx
        jmp     .loop
.found:
        mov     [rdx], rcx
        xor     eax, eax
        ret
.notfound:
        mov     rax, AF_E_NOTFOUND
        ret

; ---------------------------------------------------------------------------
; af_sv_split_byte(const af_strview *v, u8 c, af_strview *head, af_strview *tail)
;   -> af_status
;
; Splits at the first occurrence of `c`, excluding the delimiter from both
; halves. AF_E_NOTFOUND leaves both outputs untouched. `head` and `tail` may
; alias `v`; the source fields are read before either is written.
; ---------------------------------------------------------------------------
        global af_sv_split_byte
af_sv_split_byte:
        AF_ENTER 16
        mov     rbx, rdx                ; head
        mov     r12, rcx                ; tail
        mov     r13, [rdi + SV_PTR]
        mov     r14, [rdi + SV_LEN]
        lea     rdx, [rsp]
        call    af_sv_find_byte
        test    rax, rax
        js      .done
        mov     r15, [rsp]              ; index of delimiter
        mov     [rbx + SV_PTR], r13
        mov     [rbx + SV_LEN], r15
        lea     rax, [r13 + r15 + 1]
        mov     [r12 + SV_PTR], rax
        mov     rax, r14
        sub     rax, r15
        dec     rax
        mov     [r12 + SV_LEN], rax
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_sv_to_u64(const af_strview *v, u64 *out) -> af_status
;
; Strict decimal; rejects an empty view, any non-digit, and any overflow.
; ---------------------------------------------------------------------------
        global af_sv_to_u64
af_sv_to_u64:
        mov     rdx, rsi
        mov     rsi, [rdi + SV_LEN]
        mov     rdi, [rdi + SV_PTR]
        jmp     af_dec_to_u64

; ---------------------------------------------------------------------------
; Accessors.
; ---------------------------------------------------------------------------
        global af_sv_ptr
af_sv_ptr:
        mov     rax, [rdi + SV_PTR]
        ret

        global af_sv_len
af_sv_len:
        mov     rax, [rdi + SV_LEN]
        ret

        global af_sv_struct_size
af_sv_struct_size:
        mov     eax, SV_SIZE
        ret
