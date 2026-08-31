; AsmFlow — bounded growable byte buffer.
;
; Every piece of variable-length inbound data — HTTP headers, request bodies,
; SSE events, MCP frames, control frames, child stderr — lands in one of these.
; The buffer therefore carries its own ceiling rather than trusting callers to
; remember one, and every growth step goes through checked arithmetic
; (AGENTS.md invariants 7 and 8).
;
; Layout:
;   +0  data      (owned, NULL until first growth)
;   +8  len       (bytes in use)
;   +16 cap       (bytes allocated)
;   +24 max       (hard ceiling; append past it returns AF_E_LIMIT)
;
; Ownership: af_buf_init borrows the caller's storage for the struct itself and
; owns whatever it allocates for `data`. af_buf_free releases `data`.
; af_buf_take TRANSFERS `data` to the caller and leaves the buffer empty.

        bits 64
        default rel

%include "asmflow.inc"

        extern af_alloc
        extern af_realloc
        extern af_free
        extern af_add_size
        extern af_grow_size
        extern af_mem_copy
        extern af_mem_zero
        extern af_cstr_len
        extern af_u64_to_dec

%define BUF_DATA 0
%define BUF_LEN  8
%define BUF_CAP  16
%define BUF_MAX  24
%define BUF_SIZE 32

        section .text

; ---------------------------------------------------------------------------
; af_buf_init(af_buffer *b, u64 max) -> af_status
;
; No allocation happens here. A buffer that never receives data costs nothing,
; which matters because every connection object embeds several.
; ---------------------------------------------------------------------------
        global af_buf_init
af_buf_init:
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid                ; zero never means "unlimited"
        mov     qword [rdi + BUF_DATA], 0
        mov     qword [rdi + BUF_LEN], 0
        mov     qword [rdi + BUF_CAP], 0
        mov     [rdi + BUF_MAX], rsi
        xor     eax, eax
        ret
.invalid:
        mov     rax, AF_E_INVALID
        ret

; ---------------------------------------------------------------------------
; af_buf_free(af_buffer *b) -> void
;
; Idempotent, so a single cleanup label may free every buffer of a partially
; constructed object without tracking which ones were reached.
; ---------------------------------------------------------------------------
        global af_buf_free
af_buf_free:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, [rbx + BUF_DATA]
        call    af_free
        mov     qword [rbx + BUF_DATA], 0
        mov     qword [rbx + BUF_LEN], 0
        mov     qword [rbx + BUF_CAP], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_buf_free_secure(af_buffer *b) -> void
;
; Same as af_buf_free but wipes the payload first. Used for credential buffers
; (SECURITY_MODEL.md 6).
; ---------------------------------------------------------------------------
        global af_buf_free_secure
af_buf_free_secure:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, [rbx + BUF_DATA]
        test    rdi, rdi
        jz      .release
        mov     rsi, [rbx + BUF_CAP]
        call    af_mem_zero
.release:
        mov     rdi, rbx
        call    af_buf_free
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_buf_clear(af_buffer *b) -> void
;
; Drops the contents but keeps the allocation, so a connection can be reused
; without a fresh malloc per message.
; ---------------------------------------------------------------------------
        global af_buf_clear
af_buf_clear:
        test    rdi, rdi
        jz      .done
        mov     qword [rdi + BUF_LEN], 0
.done:
        ret

; ---------------------------------------------------------------------------
; af_buf_clear_secure(af_buffer *b) -> void
;
; Drops the contents but keeps the allocation, wiping the whole allocation
; first.  Wiping capacity rather than only length also removes bytes left behind
; by a previous consume or by a shorter replacement (SECURITY_MODEL.md 6).
; ---------------------------------------------------------------------------
        global af_buf_clear_secure
af_buf_clear_secure:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, [rbx + BUF_DATA]
        test    rdi, rdi
        jz      .cleared
        mov     rsi, [rbx + BUF_CAP]
        call    af_mem_zero
.cleared:
        mov     qword [rbx + BUF_LEN], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_buf_reserve(af_buffer *b, u64 additional) -> af_status
;
; Guarantees room for `additional` more bytes past the current length.
;
;   AF_E_LIMIT     len + additional exceeds max
;   AF_E_OVERFLOW  the sum does not fit in 64 bits
;   AF_E_NOMEM     the allocator refused
; ---------------------------------------------------------------------------
        global af_buf_reserve
af_buf_reserve:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        test    rsi, rsi
        jz      .ok                     ; reserving nothing always succeeds

        ; needed = len + additional
        mov     rdi, [rbx + BUF_LEN]
        lea     rdx, [rsp]
        call    af_add_size
        test    rax, rax
        js      .done
        mov     r12, [rsp]              ; needed

        cmp     r12, [rbx + BUF_CAP]
        jbe     .ok                     ; already large enough

        cmp     r12, [rbx + BUF_MAX]
        ja      .limit

        ; new_cap = grow(cap, needed, max)
        mov     rdi, [rbx + BUF_CAP]
        mov     rsi, r12
        mov     rdx, [rbx + BUF_MAX]
        lea     rcx, [rsp + 8]
        call    af_grow_size
        test    rax, rax
        js      .done
        mov     r13, [rsp + 8]          ; new capacity

        mov     rdi, [rbx + BUF_DATA]
        mov     rsi, r13
        call    af_realloc
        test    rax, rax
        jz      .nomem
        mov     [rbx + BUF_DATA], rax
        mov     [rbx + BUF_CAP], r13
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.limit:
        mov     rax, AF_E_LIMIT
        AF_LEAVE
.nomem:
        mov     rax, AF_E_NOMEM
        AF_LEAVE
.invalid:
        mov     rax, AF_E_INVALID
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_buf_append(af_buffer *b, const void *p, u64 n) -> af_status
;
; Ownership: `p` is BORROWED; its bytes are copied. On any failure the buffer is
; left exactly as it was, so a rejected oversized frame cannot leave a partial
; message behind for the next parse step to misread.
; ---------------------------------------------------------------------------
        global af_buf_append
af_buf_append:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        test    r13, r13
        jz      .ok
        test    r12, r12
        jz      .invalid

        mov     rdi, rbx
        mov     rsi, r13
        call    af_buf_reserve
        test    rax, rax
        js      .done

        mov     rdi, [rbx + BUF_DATA]
        add     rdi, [rbx + BUF_LEN]
        mov     rsi, r12
        mov     rdx, r13
        call    af_mem_copy
        add     [rbx + BUF_LEN], r13
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.invalid:
        mov     rax, AF_E_INVALID
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_buf_append_byte(af_buffer *b, u8 c) -> af_status
; ---------------------------------------------------------------------------
        global af_buf_append_byte
af_buf_append_byte:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     [rsp], sil
        mov     rdi, rbx
        mov     rsi, 1
        call    af_buf_reserve
        test    rax, rax
        js      .done
        mov     rcx, [rbx + BUF_DATA]
        add     rcx, [rbx + BUF_LEN]
        mov     al, [rsp]
        mov     [rcx], al
        inc     qword [rbx + BUF_LEN]
        xor     eax, eax
.done:
        AF_LEAVE
.invalid:
        mov     rax, AF_E_INVALID
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_buf_append_cstr(af_buffer *b, const char *s) -> af_status
; ---------------------------------------------------------------------------
        global af_buf_append_cstr
af_buf_append_cstr:
        AF_ENTER 0
        test    rsi, rsi
        jz      .ok
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rsi
        call    af_cstr_len
        mov     rdx, rax
        mov     rdi, rbx
        mov     rsi, r12
        call    af_buf_append
        AF_LEAVE
.ok:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_buf_append_u64(af_buffer *b, u64 value) -> af_status
; ---------------------------------------------------------------------------
        global af_buf_append_u64
af_buf_append_u64:
        AF_ENTER 48
        mov     rbx, rdi
        mov     rdi, rsi
        lea     rsi, [rsp]
        mov     rdx, 32
        lea     rcx, [rsp + 32]
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, [rsp + 32]
        call    af_buf_append
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_buf_consume(af_buffer *b, u64 n) -> af_status
;
; Removes `n` bytes from the FRONT, shifting the remainder down. This is the
; operation an incremental framer performs after it has parsed a complete
; message; keeping it here means the memmove bound is checked in one place.
; ---------------------------------------------------------------------------
        global af_buf_consume
af_buf_consume:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rax, [rbx + BUF_LEN]
        cmp     rsi, rax
        ja      .range
        je      .clear_all
        mov     r12, rsi
        mov     rdi, [rbx + BUF_DATA]
        mov     rsi, rdi
        add     rsi, r12
        mov     rdx, rax
        sub     rdx, r12
        mov     r13, rdx
        ; Regions overlap; copy forward, which is safe because the destination
        ; is strictly below the source.
        call    af_mem_copy
        mov     [rbx + BUF_LEN], r13
        xor     eax, eax
        AF_LEAVE
.clear_all:
        mov     qword [rbx + BUF_LEN], 0
        xor     eax, eax
        AF_LEAVE
.range:
        mov     rax, AF_E_RANGE
        AF_LEAVE
.invalid:
        mov     rax, AF_E_INVALID
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_buf_consume_secure(af_buffer *b, u64 n) -> af_status
;
; Preserves the unconsumed suffix exactly like af_buf_consume, then wipes every
; byte outside the new logical length. This is for incremental input buffers
; that may contain both a credential-bearing request and a pipelined successor.
; ---------------------------------------------------------------------------
        global af_buf_consume_secure
af_buf_consume_secure:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        call    af_buf_consume
        test    rax, rax
        js      .done

        mov     rdi, [rbx + BUF_DATA]
        test    rdi, rdi
        jz      .ok
        mov     rcx, [rbx + BUF_LEN]
        add     rdi, rcx
        mov     rsi, [rbx + BUF_CAP]
        sub     rsi, rcx
        jz      .ok
        call    af_mem_zero
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_buf_take(af_buffer *b, u8 **out_data, u64 *out_len) -> af_status
;
; TRANSFERS the payload to the caller, who must release it with af_free. The
; buffer is reset to its initial state and stays usable.
; ---------------------------------------------------------------------------
        global af_buf_take
af_buf_take:
        test    rdi, rdi
        jz      .invalid
        mov     rax, [rdi + BUF_DATA]
        mov     [rsi], rax
        mov     rax, [rdi + BUF_LEN]
        mov     [rdx], rax
        mov     qword [rdi + BUF_DATA], 0
        mov     qword [rdi + BUF_LEN], 0
        mov     qword [rdi + BUF_CAP], 0
        xor     eax, eax
        ret
.invalid:
        mov     rax, AF_E_INVALID
        ret

; ---------------------------------------------------------------------------
; Accessors. `af_buf_data` returns a BORROWED pointer that is invalidated by the
; next growth; callers must not hold it across an append.
; ---------------------------------------------------------------------------
        global af_buf_data
af_buf_data:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + BUF_DATA]
.done:
        ret

        global af_buf_len
af_buf_len:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + BUF_LEN]
.done:
        ret

        global af_buf_cap
af_buf_cap:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + BUF_CAP]
.done:
        ret

        global af_buf_max
af_buf_max:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + BUF_MAX]
.done:
        ret

        global af_buf_struct_size
af_buf_struct_size:
        mov     eax, BUF_SIZE
        ret
