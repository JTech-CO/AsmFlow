; AsmFlow — JSON serialisation.
;
; Everything the runtime emits as JSON goes through here: control-plane
; responses and events, data-plane error envelopes, MCP requests, diagnostic
; exports. Three properties matter more than speed.
;
; Grammar by construction. The writer tracks nesting, so separators and the
; object/array structure are produced rather than remembered. A call that does
; not fit — a key inside an array, two keys in a row, an `end_array` closing an
; object — sets a sticky error instead of emitting malformed output that a peer
; would have to reject.
;
; Sanitised strings. Much of what the control plane reports is third-party text:
; an MCP server's advertised name, a tool description, an upstream error
; message. Control characters are escaped, and invalid UTF-8 is replaced with
; U+FFFD rather than passed through. A raw control byte reaching an operator's
; terminal through a JSON string is the injection SECURITY_MODEL.md 17 exists to
; prevent, and invalid UTF-8 would make the frame undecodable for a strict peer.
;
; Sticky failure. Once a write fails — the output buffer hit its ceiling, the
; nesting exceeded its limit — every later call is a no-op and the status is
; retained. Callers check once at the end rather than after each field.

        bits 64
        default rel

%include "asmflow.inc"
%include "jsonw.inc"

        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_append_u64
        extern af_buf_len
        extern af_cstr_len
        extern af_mem_zero

        section .rodata
hexdigits: db "0123456789abcdef"
lit_true:  db "true"
lit_false: db "false"
lit_null:  db "null"
esc_u:     db "\u00"
esc_b:     db "\b"
esc_f:     db "\f"
esc_n:     db "\n"
esc_r:     db "\r"
esc_t:     db "\t"
esc_quote: db '\"'
esc_slash: db "\\"
; U+FFFD REPLACEMENT CHARACTER, already UTF-8 encoded.
replacement: db 0xEF, 0xBF, 0xBD

        section .text

; ---------------------------------------------------------------------------
; af_jw_init(af_json_writer *w, af_buffer *out) -> af_status
;
; Ownership: `out` is BORROWED and must outlive the writer. The writer appends;
; it never clears, so a caller may frame a message around what it produces.
; ---------------------------------------------------------------------------
        global af_jw_init
af_jw_init:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     [rbx + JW_OUT], rsi
        mov     qword [rbx + JW_DEPTH], 0
        mov     qword [rbx + JW_STATUS], AF_OK
        mov     qword [rbx + JW_ROOT_DONE], 0
        lea     rdi, [rbx + JW_STACK]
        mov     rsi, AF_JW_MAX_DEPTH
        call    af_mem_zero
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_jw_status(const af_json_writer *w) -> af_status
; ---------------------------------------------------------------------------
        global af_jw_status
af_jw_status:
        mov     rax, AF_E_INVALID
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + JW_STATUS]
.done:
        ret

; ---------------------------------------------------------------------------
; af_jw_finish(af_json_writer *w) -> af_status
;
; The sticky status, plus a check that every container was closed. An unbalanced
; document is a defect in the caller, and catching it here is much cheaper than
; discovering it in a peer's parser.
; ---------------------------------------------------------------------------
        global af_jw_finish
af_jw_finish:
        test    rdi, rdi
        jz      .invalid
        mov     rax, [rdi + JW_STATUS]
        test    rax, rax
        js      .done
        cmp     qword [rdi + JW_DEPTH], 0
        jne     .unbalanced
        xor     eax, eax
.done:
        ret
.unbalanced:
        mov     rax, AF_E_INTERNAL
        mov     [rdi + JW_STATUS], rax
        ret
.invalid:
        mov     rax, AF_E_INVALID
        ret

; ---------------------------------------------------------------------------
; af_jw_fail(af_json_writer *w, af_status code) -> af_status
;
; Private. Records the FIRST failure and returns it; a later one does not
; overwrite the cause.
; ---------------------------------------------------------------------------
af_jw_fail:
        mov     rax, [rdi + JW_STATUS]
        test    rax, rax
        js      .keep
        mov     [rdi + JW_STATUS], rsi
        mov     rax, rsi
.keep:
        ret

; ---------------------------------------------------------------------------
; af_jw_prepare_value(af_json_writer *w) -> af_status
;
; Private. Emits the separator a value needs in the current container and
; updates the level state. Rejects a value where a key is expected.
; ---------------------------------------------------------------------------
af_jw_prepare_value:
        AF_ENTER 0
        mov     rbx, rdi
        mov     rax, [rbx + JW_STATUS]
        test    rax, rax
        js      .done

        mov     r12, [rbx + JW_DEPTH]
        test    r12, r12
        jz      .top_level              ; a bare value at the document root

        movzx   r13d, byte [rbx + JW_STACK + r12 - 1]
        test    r13b, AF_JW_ARRAY
        jz      .in_object

        ; array: a comma before every element except the first
        test    r13b, AF_JW_HAS_ITEM
        jz      .mark_item
        mov     rdi, [rbx + JW_OUT]
        mov     rsi, ','
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
.mark_item:
        or      byte [rbx + JW_STACK + r12 - 1], AF_JW_HAS_ITEM
        AF_LEAVE_OK

.in_object:
        ; object: a value is legal only immediately after a key
        test    r13b, AF_JW_WANT_VALUE
        jz      .value_without_key
        and     byte [rbx + JW_STACK + r12 - 1], ~AF_JW_WANT_VALUE
        AF_LEAVE_OK

.top_level:
        ; Exactly one value may sit at the root of a document; a second would
        ; concatenate two. The question is about THIS writer, not about the
        ; buffer, which may already hold earlier complete frames.
        cmp     qword [rbx + JW_ROOT_DONE], 0
        jne     .second_root
        mov     qword [rbx + JW_ROOT_DONE], 1
        AF_LEAVE_OK

.second_root:
        mov     rdi, rbx
        mov     rsi, AF_E_INTERNAL
        call    af_jw_fail
        AF_LEAVE
.value_without_key:
        mov     rdi, rbx
        mov     rsi, AF_E_INTERNAL
        call    af_jw_fail
        AF_LEAVE
.buffer_failed:
        mov     rsi, rax
        mov     rdi, rbx
        call    af_jw_fail
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_push(af_json_writer *w, u8 kind) -> af_status
;
; Private. Opens a container level.
; ---------------------------------------------------------------------------
af_jw_push:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     rax, [rbx + JW_DEPTH]
        cmp     rax, AF_JW_MAX_DEPTH
        jae     .too_deep
        mov     byte [rbx + JW_STACK + rax], r12b
        inc     qword [rbx + JW_DEPTH]
        AF_LEAVE_OK
.too_deep:
        mov     rdi, rbx
        mov     rsi, AF_E_JSON_DEPTH
        call    af_jw_fail
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_begin_object(af_json_writer *w) -> af_status
; ---------------------------------------------------------------------------
        global af_jw_begin_object
af_jw_begin_object:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, rbx
        call    af_jw_prepare_value
        test    rax, rax
        js      .done
        mov     rdi, [rbx + JW_OUT]
        mov     rsi, '{'
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
        mov     rdi, rbx
        xor     esi, esi                ; object
        call    af_jw_push
        AF_LEAVE
.buffer_failed:
        mov     rsi, rax
        mov     rdi, rbx
        call    af_jw_fail
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_begin_array(af_json_writer *w) -> af_status
; ---------------------------------------------------------------------------
        global af_jw_begin_array
af_jw_begin_array:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, rbx
        call    af_jw_prepare_value
        test    rax, rax
        js      .done
        mov     rdi, [rbx + JW_OUT]
        mov     rsi, '['
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
        mov     rdi, rbx
        mov     rsi, AF_JW_ARRAY
        call    af_jw_push
        AF_LEAVE
.buffer_failed:
        mov     rsi, rax
        mov     rdi, rbx
        call    af_jw_fail
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_end(af_json_writer *w, u8 expected_kind, u8 closing_byte) -> af_status
;
; Private. Closes a level, checking that it matches what was opened.
; ---------------------------------------------------------------------------
af_jw_end:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi                ; expected kind
        mov     r13, rdx                ; closing byte
        mov     rax, [rbx + JW_STATUS]
        test    rax, rax
        js      .done

        mov     rax, [rbx + JW_DEPTH]
        test    rax, rax
        jz      .mismatch
        movzx   ecx, byte [rbx + JW_STACK + rax - 1]
        mov     edx, ecx
        and     edx, AF_JW_ARRAY
        cmp     rdx, r12
        jne     .mismatch
        ; A dangling key with no value would produce `{"a":}`.
        test    cl, AF_JW_WANT_VALUE
        jnz     .mismatch

        dec     qword [rbx + JW_DEPTH]
        mov     rdi, [rbx + JW_OUT]
        mov     rsi, r13
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
        AF_LEAVE_OK
.mismatch:
        mov     rdi, rbx
        mov     rsi, AF_E_INTERNAL
        call    af_jw_fail
        AF_LEAVE
.buffer_failed:
        mov     rsi, rax
        mov     rdi, rbx
        call    af_jw_fail
        AF_LEAVE
.done:
        AF_LEAVE

        global af_jw_end_object
af_jw_end_object:
        AF_ENTER 0
        xor     esi, esi
        mov     rdx, '}'
        call    af_jw_end
        AF_LEAVE

        global af_jw_end_array
af_jw_end_array:
        AF_ENTER 0
        mov     rsi, AF_JW_ARRAY
        mov     rdx, ']'
        call    af_jw_end
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_key_n(af_json_writer *w, const char *key, u64 len) -> af_status
;
; Only legal directly inside an object, and not twice in a row.
; ---------------------------------------------------------------------------
        global af_jw_key_n
af_jw_key_n:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx
        mov     rax, [rbx + JW_STATUS]
        test    rax, rax
        js      .done

        mov     r12, [rbx + JW_DEPTH]
        test    r12, r12
        jz      .not_in_object
        movzx   r13d, byte [rbx + JW_STACK + r12 - 1]
        test    r13b, AF_JW_ARRAY
        jnz     .not_in_object
        test    r13b, AF_JW_WANT_VALUE
        jnz     .not_in_object          ; two keys in a row

        test    r13b, AF_JW_HAS_ITEM
        jz      .no_comma
        mov     rdi, [rbx + JW_OUT]
        mov     rsi, ','
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
.no_comma:
        mov     rdi, rbx
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_jw_emit_string
        test    rax, rax
        js      .done
        mov     rdi, [rbx + JW_OUT]
        mov     rsi, ':'
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
        mov     r12, [rbx + JW_DEPTH]
        or      byte [rbx + JW_STACK + r12 - 1], AF_JW_HAS_ITEM | AF_JW_WANT_VALUE
        AF_LEAVE_OK
.not_in_object:
        mov     rdi, rbx
        mov     rsi, AF_E_INTERNAL
        call    af_jw_fail
        AF_LEAVE
.buffer_failed:
        mov     rsi, rax
        mov     rdi, rbx
        call    af_jw_fail
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_key(af_json_writer *w, const char *key) -> af_status
; ---------------------------------------------------------------------------
        global af_jw_key
af_jw_key:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, r12
        call    af_cstr_len
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, rax
        call    af_jw_key_n
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_string_n(af_json_writer *w, const char *s, u64 len) -> af_status
; ---------------------------------------------------------------------------
        global af_jw_string_n
af_jw_string_n:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx
        mov     rdi, rbx
        call    af_jw_prepare_value
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_jw_emit_string
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_string(af_json_writer *w, const char *s) -> af_status
;
; A NULL string writes JSON null, which is what a nullable database column
; naturally produces.
; ---------------------------------------------------------------------------
        global af_jw_string
af_jw_string:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        test    r12, r12
        jz      .null
        mov     rdi, r12
        call    af_cstr_len
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, rax
        call    af_jw_string_n
        AF_LEAVE
.null:
        mov     rdi, rbx
        call    af_jw_null
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_emit_string(af_json_writer *w, const char *s, u64 len) -> af_status
;
; Private. Writes a quoted, escaped, UTF-8-sanitised string.
;
; Escaped: the two mandatory characters (`"` and `\`), every byte below 0x20,
; and DEL. Bytes above 0x7F are validated as UTF-8 and passed through when the
; sequence is well formed; an ill-formed sequence becomes U+FFFD.
;
; Passing invalid UTF-8 through would make the frame undecodable for a strict
; peer, and passing a control byte through would let a remote string move an
; operator's cursor.
; ---------------------------------------------------------------------------
af_jw_emit_string:
        AF_ENTER 32
        mov     rbx, rdi                ; writer
        mov     r12, rsi                ; source
        mov     r13, rdx                ; length
        mov     r14, [rbx + JW_OUT]

        mov     rdi, r14
        mov     rsi, '"'
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed

        xor     r15, r15                ; cursor
.loop:
        cmp     r15, r13
        jae     .close
        movzx   eax, byte [r12 + r15]

        cmp     al, 0x80
        jae     .multibyte
        cmp     al, 0x20
        jb      .control
        cmp     al, '"'
        je      .quote
        cmp     al, '\'
        je      .backslash
        cmp     al, 0x7F
        je      .control

        mov     rdi, r14
        movzx   esi, al
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
        inc     r15
        jmp     .loop

.quote:
        mov     rdi, r14
        lea     rsi, [esc_quote]
        mov     rdx, 2
        call    af_buf_append
        test    rax, rax
        js      .buffer_failed
        inc     r15
        jmp     .loop

.backslash:
        mov     rdi, r14
        lea     rsi, [esc_slash]
        mov     rdx, 2
        call    af_buf_append
        test    rax, rax
        js      .buffer_failed
        inc     r15
        jmp     .loop

; The five characters with a short escape use it; everything else below 0x20
; and DEL become \u00XX.
.control:
        mov     [rsp], rax
        cmp     al, 8
        je      .esc_b
        cmp     al, 12
        je      .esc_f
        cmp     al, 10
        je      .esc_n
        cmp     al, 13
        je      .esc_r
        cmp     al, 9
        je      .esc_t

        mov     rdi, r14
        lea     rsi, [esc_u]
        mov     rdx, 4
        call    af_buf_append
        test    rax, rax
        js      .buffer_failed
        mov     rax, [rsp]
        mov     rcx, rax
        shr     rcx, 4
        and     rcx, 15
        lea     rdx, [hexdigits]
        movzx   esi, byte [rdx + rcx]
        mov     rdi, r14
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
        mov     rax, [rsp]
        and     rax, 15
        lea     rdx, [hexdigits]
        movzx   esi, byte [rdx + rax]
        mov     rdi, r14
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
        inc     r15
        jmp     .loop
.esc_b:
        lea     rsi, [esc_b]
        jmp     .emit_short
.esc_f:
        lea     rsi, [esc_f]
        jmp     .emit_short
.esc_n:
        lea     rsi, [esc_n]
        jmp     .emit_short
.esc_r:
        lea     rsi, [esc_r]
        jmp     .emit_short
.esc_t:
        lea     rsi, [esc_t]
.emit_short:
        mov     rdi, r14
        mov     rdx, 2
        call    af_buf_append
        test    rax, rax
        js      .buffer_failed
        inc     r15
        jmp     .loop

; A multi-byte sequence is copied verbatim when it is well formed, and replaced
; when it is not. Validation covers length, continuation bytes, the surrogate
; range, and overlong encodings.
.multibyte:
        mov     rdi, r12
        add     rdi, r15
        mov     rsi, r13
        sub     rsi, r15
        lea     rdx, [rsp + 8]
        call    af_utf8_sequence_length
        test    rax, rax
        jz      .replace
        mov     rdi, r14
        mov     rsi, r12
        add     rsi, r15
        mov     rdx, rax
        add     r15, rax
        call    af_buf_append
        test    rax, rax
        js      .buffer_failed
        jmp     .loop
.replace:
        mov     rdi, r14
        lea     rsi, [replacement]
        mov     rdx, 3
        call    af_buf_append
        test    rax, rax
        js      .buffer_failed
        inc     r15                     ; skip exactly one bad byte
        jmp     .loop

.close:
        mov     rdi, r14
        mov     rsi, '"'
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
        AF_LEAVE_OK
.buffer_failed:
        mov     rsi, rax
        mov     rdi, rbx
        call    af_jw_fail
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_utf8_sequence_length(const u8 *p, u64 available, u32 *out_codepoint)
;   -> u64 (0 = not a valid sequence at p)
;
; Rejects continuation bytes in the lead position, truncated sequences,
; overlong encodings, the UTF-16 surrogate range, and anything above U+10FFFF.
; Shared with the HTTP and MCP layers, which have the same problem.
; ---------------------------------------------------------------------------
        global af_utf8_sequence_length
af_utf8_sequence_length:
        test    rsi, rsi
        jz      .bad
        movzx   eax, byte [rdi]

        cmp     al, 0x80
        jb      .one
        cmp     al, 0xC2
        jb      .bad                    ; continuation byte, or an overlong C0/C1
        cmp     al, 0xE0
        jb      .two
        cmp     al, 0xF0
        jb      .three
        cmp     al, 0xF5
        jb      .four
        jmp     .bad                    ; above U+10FFFF

.one:
        mov     [rdx], eax
        mov     eax, 1
        ret

.two:
        cmp     rsi, 2
        jb      .bad
        movzx   ecx, byte [rdi + 1]
        mov     r8d, ecx
        and     r8d, 0xC0
        cmp     r8d, 0x80
        jne     .bad
        and     eax, 0x1F
        shl     eax, 6
        and     ecx, 0x3F
        or      eax, ecx
        mov     [rdx], eax
        mov     eax, 2
        ret

.three:
        cmp     rsi, 3
        jb      .bad
        movzx   ecx, byte [rdi + 1]
        mov     r8d, ecx
        and     r8d, 0xC0
        cmp     r8d, 0x80
        jne     .bad
        movzx   r9d, byte [rdi + 2]
        mov     r10d, r9d
        and     r10d, 0xC0
        cmp     r10d, 0x80
        jne     .bad
        and     eax, 0x0F
        shl     eax, 12
        and     ecx, 0x3F
        shl     ecx, 6
        or      eax, ecx
        and     r9d, 0x3F
        or      eax, r9d
        cmp     eax, 0x800
        jb      .bad                    ; overlong
        cmp     eax, 0xD800
        jb      .three_ok
        cmp     eax, 0xDFFF
        jbe     .bad                    ; UTF-16 surrogate
.three_ok:
        mov     [rdx], eax
        mov     eax, 3
        ret

.four:
        cmp     rsi, 4
        jb      .bad
        movzx   ecx, byte [rdi + 1]
        mov     r8d, ecx
        and     r8d, 0xC0
        cmp     r8d, 0x80
        jne     .bad
        movzx   r9d, byte [rdi + 2]
        mov     r10d, r9d
        and     r10d, 0xC0
        cmp     r10d, 0x80
        jne     .bad
        movzx   r11d, byte [rdi + 3]
        mov     r8d, r11d
        and     r8d, 0xC0
        cmp     r8d, 0x80
        jne     .bad
        and     eax, 0x07
        shl     eax, 18
        and     ecx, 0x3F
        shl     ecx, 12
        or      eax, ecx
        and     r9d, 0x3F
        shl     r9d, 6
        or      eax, r9d
        and     r11d, 0x3F
        or      eax, r11d
        cmp     eax, 0x10000
        jb      .bad                    ; overlong
        cmp     eax, 0x10FFFF
        ja      .bad
        mov     [rdx], eax
        mov     eax, 4
        ret

.bad:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_utf8_validate(const void *p, u64 n) -> i64 (1 = the whole span is valid)
; ---------------------------------------------------------------------------
        global af_utf8_validate
af_utf8_validate:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        xor     r13, r13
.loop:
        cmp     r13, r12
        jae     .yes
        mov     rdi, rbx
        add     rdi, r13
        mov     rsi, r12
        sub     rsi, r13
        lea     rdx, [rsp]
        call    af_utf8_sequence_length
        test    rax, rax
        jz      .no
        add     r13, rax
        jmp     .loop
.yes:
        mov     eax, 1
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_uint(af_json_writer *w, u64 value) -> af_status
; ---------------------------------------------------------------------------
        global af_jw_uint
af_jw_uint:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     rdi, rbx
        call    af_jw_prepare_value
        test    rax, rax
        js      .done
        mov     rdi, [rbx + JW_OUT]
        mov     rsi, [rsp]
        call    af_buf_append_u64
        test    rax, rax
        js      .buffer_failed
        AF_LEAVE_OK
.buffer_failed:
        mov     rsi, rax
        mov     rdi, rbx
        call    af_jw_fail
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_int(af_json_writer *w, i64 value) -> af_status
; ---------------------------------------------------------------------------
        global af_jw_int
af_jw_int:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        call    af_jw_prepare_value
        test    rax, rax
        js      .done
        test    r12, r12
        jns     .magnitude
        mov     rdi, [rbx + JW_OUT]
        mov     rsi, '-'
        call    af_buf_append_byte
        test    rax, rax
        js      .buffer_failed
        neg     r12
.magnitude:
        mov     rdi, [rbx + JW_OUT]
        mov     rsi, r12
        call    af_buf_append_u64
        test    rax, rax
        js      .buffer_failed
        AF_LEAVE_OK
.buffer_failed:
        mov     rsi, rax
        mov     rdi, rbx
        call    af_jw_fail
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_literal(af_json_writer *w, const char *text, u64 len) -> af_status
;
; Private. Emits one of the three bare literals.
; ---------------------------------------------------------------------------
af_jw_literal:
        AF_ENTER 16
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx
        mov     rdi, rbx
        call    af_jw_prepare_value
        test    rax, rax
        js      .done
        mov     rdi, [rbx + JW_OUT]
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_buf_append
        test    rax, rax
        js      .buffer_failed
        AF_LEAVE_OK
.buffer_failed:
        mov     rsi, rax
        mov     rdi, rbx
        call    af_jw_fail
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_bool(af_json_writer *w, i64 value) -> af_status
; ---------------------------------------------------------------------------
        global af_jw_bool
af_jw_bool:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .false
        lea     rsi, [lit_true]
        mov     rdx, 4
        call    af_jw_literal
        AF_LEAVE
.false:
        lea     rsi, [lit_false]
        mov     rdx, 5
        call    af_jw_literal
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_jw_null(af_json_writer *w) -> af_status
; ---------------------------------------------------------------------------
        global af_jw_null
af_jw_null:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        lea     rsi, [lit_null]
        mov     rdx, 4
        call    af_jw_literal
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; Convenience: a key and its value in one call. These are what most call sites
; use, and they keep the two halves of a member impossible to separate.
; ---------------------------------------------------------------------------
        global af_jw_member_string
af_jw_member_string:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rdx                ; value
        call    af_jw_key
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r12
        call    af_jw_string
.done:
        AF_LEAVE

        global af_jw_member_string_n
af_jw_member_string_n:
        AF_ENTER 16
        mov     rbx, rdi
        mov     [rsp], rdx              ; value
        mov     [rsp + 8], rcx          ; value length
        call    af_jw_key
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_jw_string_n
.done:
        AF_LEAVE

        global af_jw_member_uint
af_jw_member_uint:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rdx
        call    af_jw_key
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r12
        call    af_jw_uint
.done:
        AF_LEAVE

        global af_jw_member_int
af_jw_member_int:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rdx
        call    af_jw_key
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r12
        call    af_jw_int
.done:
        AF_LEAVE

        global af_jw_member_bool
af_jw_member_bool:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rdx
        call    af_jw_key
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r12
        call    af_jw_bool
.done:
        AF_LEAVE

        global af_jw_member_null
af_jw_member_null:
        AF_ENTER 0
        mov     rbx, rdi
        call    af_jw_key
        test    rax, rax
        js      .done
        mov     rdi, rbx
        call    af_jw_null
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_jw_struct_size() -> u64
; ---------------------------------------------------------------------------
        global af_jw_struct_size
af_jw_struct_size:
        mov     eax, JW_SIZE
        ret
