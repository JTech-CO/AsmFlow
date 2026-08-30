; AsmFlow — snapshot lifetime, unknown-key sweep, and plaintext-secret refusal.
;
; The vocabulary lives in config_tables.asm and the field accessors in
; config_field.asm; this file holds the three rules that apply to the document
; as a whole rather than to one field.
;
; Failure discipline: a rejected document produces no snapshot at all. Nothing
; partially built is published and the caller's previous snapshot is untouched
; (docs/CONFIGURATION.md 13).

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"
%include "config.inc"

        extern af_alloc
        extern af_free
        extern af_mem_zero
        extern af_mem_eq
        extern af_cstr_len
        extern af_arena_init
        extern af_arena_finalize

        extern af_json_type
        extern af_json_array_at
        extern af_json_array_count
        extern af_json_iter_begin
        extern af_json_iter_key
        extern af_json_iter_key_len
        extern af_json_iter_value
        extern af_json_iter_next

        extern af_cfg_err_fail
        extern af_cfg_err_push_key
        extern af_cfg_err_push_index
        extern af_cfg_err_truncate
        extern af_cfg_err_depth

        extern tbl_plaintext_keys
        extern m_unknown_key
        extern m_plaintext

%define CFG_ARENA_CHUNK (64 * 1024)
%define CFG_ARENA_MAX   (8 * 1024 * 1024)

        section .text

; ---------------------------------------------------------------------------
; af_config_release(af_config *cfg) -> void
;
; Drops one reference; the last one releases the arena and the block. A request
; holds a reference for its whole lifetime, so a reload cannot pull the
; configuration out from under an in-flight attempt.
; ---------------------------------------------------------------------------
        global af_config_release
af_config_release:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rax, [rbx + CFG_REFCOUNT]
        test    rax, rax
        jz      .done                   ; already released
        dec     rax
        mov     [rbx + CFG_REFCOUNT], rax
        test    rax, rax
        jnz     .done
        lea     rdi, [rbx + CFG_ARENA]
        call    af_arena_finalize
        mov     rdi, rbx
        call    af_free
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_config_retain(af_config *cfg) -> af_config *
; ---------------------------------------------------------------------------
        global af_config_retain
af_config_retain:
        mov     rax, rdi
        test    rdi, rdi
        jz      .done
        inc     qword [rdi + CFG_REFCOUNT]
.done:
        ret

; ---------------------------------------------------------------------------
; af_config_refcount(const af_config *cfg) -> u64
; ---------------------------------------------------------------------------
        global af_config_refcount
af_config_refcount:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CFG_REFCOUNT]
.done:
        ret

; ---------------------------------------------------------------------------
; af_config_new(af_config **out) -> af_status
;
; Allocates a zeroed snapshot with its arena initialised and one reference held.
; Every string and record the snapshot owns is later allocated from that arena,
; so releasing it is one finalize plus one free.
; ---------------------------------------------------------------------------
        global af_config_new
af_config_new:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, CFG_SIZE
        call    af_alloc
        test    rax, rax
        jz      .nomem
        mov     r12, rax
        mov     rdi, r12
        mov     rsi, CFG_SIZE
        call    af_mem_zero
        lea     rdi, [r12 + CFG_ARENA]
        mov     rsi, CFG_ARENA_CHUNK
        mov     rdx, CFG_ARENA_MAX
        call    af_arena_init
        test    rax, rax
        js      .release
        mov     qword [r12 + CFG_REFCOUNT], 1
        mov     [rbx], r12
        AF_LEAVE_OK
.release:
        mov     rdi, r12
        call    af_free
        AF_LEAVE_ERR AF_E_INTERNAL
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_config_arena(af_config *cfg) -> af_arena * (BORROWED)
; ---------------------------------------------------------------------------
        global af_config_arena
af_config_arena:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        lea     rax, [rdi + CFG_ARENA]
.done:
        ret

; ---------------------------------------------------------------------------
; af_cfg_check_keys(json_t *object, const void *allowed, af_cfg_error *err)
;   -> af_status
;
; The `additionalProperties: false` sweep. `allowed` is a NULL-terminated array
; of C strings. Accepting an unrecognised key silently would let a typo such as
; `store_payload` disable a privacy control while the file still looked
; correct, so the offending key is appended to the JSON Pointer and the document
; is rejected.
; ---------------------------------------------------------------------------
        global af_cfg_check_keys
af_cfg_check_keys:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi                ; object
        mov     r12, rsi                ; allowed list
        mov     r13, rdx                ; error

        mov     rdi, rbx
        call    af_json_iter_begin
        mov     r14, rax
.loop:
        test    r14, r14
        jz      .ok
        mov     rdi, r14
        call    af_json_iter_key
        mov     r15, rax                ; key
        mov     rdi, r14
        call    af_json_iter_key_len
        mov     [rsp], rax              ; key length

        ; Linear scan of the allowed list. The longest list has fourteen
        ; entries, so a hash would cost more than it saved.
        mov     rax, r12
        mov     [rsp + 8], rax
.scan:
        mov     rax, [rsp + 8]
        mov     rdi, [rax]
        test    rdi, rdi
        jz      .unknown
        call    af_cstr_len
        cmp     rax, [rsp]
        jne     .next_allowed
        mov     rax, [rsp + 8]
        mov     rdi, [rax]
        mov     rsi, r15
        mov     rdx, [rsp]
        call    af_mem_eq
        test    rax, rax
        jnz     .accepted
.next_allowed:
        add     qword [rsp + 8], 8
        jmp     .scan

.accepted:
        mov     rdi, rbx
        mov     rsi, r14
        call    af_json_iter_next
        mov     r14, rax
        jmp     .loop

.unknown:
        mov     rdi, r13
        mov     rsi, r15
        call    af_cfg_err_push_key
        mov     rdi, r13
        mov     rsi, AF_E_CFG_UNKNOWN_KEY
        lea     rdx, [m_unknown_key]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_UNKNOWN_KEY
.ok:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_cfg_reject_plaintext(json_t *value, af_cfg_error *err) -> af_status
;
; Recursive sweep for credential-shaped keys anywhere in the document
; (docs/CONFIGURATION.md 3, HARNESS.md M3 DoD 4). It runs before structural
; validation so that a file carrying a plaintext credential is refused for that
; reason, rather than for whatever else happens to be wrong with it first.
;
; Recursion is bounded: af_json_parse has already refused anything deeper than
; the configured json_max_depth.
; ---------------------------------------------------------------------------
        global af_cfg_reject_plaintext
af_cfg_reject_plaintext:
        AF_ENTER 32
        test    rdi, rdi
        jz      .ok
        mov     rbx, rdi
        mov     r12, rsi                ; error

        mov     rdi, rbx
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        je      .object
        cmp     rax, AF_JSON_ARRAY
        je      .array
.ok:
        AF_LEAVE_OK

.array:
        mov     rdi, r12
        call    af_cfg_err_depth
        mov     [rsp + 16], rax         ; pointer length before this array
        mov     rdi, rbx
        call    af_json_array_count
        mov     r13, rax
        xor     r14, r14
.array_loop:
        cmp     r14, r13
        jae     .ok
        mov     rdi, r12
        mov     rsi, r14
        call    af_cfg_err_push_index
        mov     rdi, rbx
        mov     rsi, r14
        lea     rdx, [rsp + 8]
        call    af_json_array_at
        test    rax, rax
        js      .array_next
        mov     rdi, [rsp + 8]
        mov     rsi, r12
        call    af_cfg_reject_plaintext
        test    rax, rax
        js      .done
.array_next:
        mov     rdi, r12
        mov     rsi, [rsp + 16]
        call    af_cfg_err_truncate
        inc     r14
        jmp     .array_loop

.object:
        mov     rdi, r12
        call    af_cfg_err_depth
        mov     [rsp + 16], rax
        mov     rdi, rbx
        call    af_json_iter_begin
        mov     r13, rax
.object_loop:
        test    r13, r13
        jz      .ok
        mov     rdi, r13
        call    af_json_iter_key
        mov     r14, rax

        mov     rdi, r14
        call    af_cfg_key_is_credential
        test    rax, rax
        jnz     .plaintext

        mov     rdi, r12
        mov     rsi, r14
        call    af_cfg_err_push_key
        mov     rdi, r13
        call    af_json_iter_value
        mov     rdi, rax
        mov     rsi, r12
        call    af_cfg_reject_plaintext
        mov     r15, rax
        ; Truncate only on success. Unwinding a failure must leave the pointer
        ; naming the offending key, not restore it to the enclosing object.
        test    r15, r15
        js      .fail_through
        mov     rdi, r12
        mov     rsi, [rsp + 16]
        call    af_cfg_err_truncate

        mov     rdi, rbx
        mov     rsi, r13
        call    af_json_iter_next
        mov     r13, rax
        jmp     .object_loop

.plaintext:
        mov     rdi, r12
        mov     rsi, r14
        call    af_cfg_err_push_key
        mov     rdi, r12
        mov     rsi, AF_E_CFG_PLAINTEXT
        lea     rdx, [m_plaintext]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_PLAINTEXT
.fail_through:
        mov     rax, r15
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_key_is_credential(const char *key) -> i64 (1 = credential-shaped)
;
; Case-insensitive match against the reserved names. A legitimate SecretRef uses
; `type`, `env`, `header`, `value`, `source`, and `name`, none of which appear
; on the list, so it passes cleanly.
; ---------------------------------------------------------------------------
        global af_cfg_key_is_credential
af_cfg_key_is_credential:
        AF_ENTER 16
        test    rdi, rdi
        jz      .no
        mov     rbx, rdi
        call    af_cstr_len
        mov     [rsp], rax
        lea     r12, [tbl_plaintext_keys]
.loop:
        mov     r13, [r12]
        test    r13, r13
        jz      .no
        mov     rdi, r13
        call    af_cstr_len
        cmp     rax, [rsp]
        jne     .next
        mov     rdi, rbx
        mov     rsi, r13
        mov     rdx, rax
        call    af_cfg_ci_eq
        test    rax, rax
        jnz     .yes
.next:
        add     r12, 8
        jmp     .loop
.yes:
        mov     eax, 1
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_ci_eq(const void *a, const void *b, u64 n) -> i64 (1 = equal)
;
; ASCII case-insensitive comparison over a known length. A leaf: it issues no
; call, so it needs no frame.
; ---------------------------------------------------------------------------
        global af_cfg_ci_eq
af_cfg_ci_eq:
        xor     ecx, ecx
.loop:
        cmp     rcx, rdx
        jae     .equal
        movzx   eax, byte [rdi + rcx]
        movzx   r8d, byte [rsi + rcx]
        cmp     al, 'A'
        jb      .a_done
        cmp     al, 'Z'
        ja      .a_done
        add     al, 32
.a_done:
        cmp     r8b, 'A'
        jb      .b_done
        cmp     r8b, 'Z'
        ja      .b_done
        add     r8b, 32
.b_done:
        cmp     al, r8b
        jne     .differ
        inc     rcx
        jmp     .loop
.equal:
        mov     eax, 1
        ret
.differ:
        xor     eax, eax
        ret
