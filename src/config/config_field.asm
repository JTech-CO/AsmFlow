; AsmFlow — typed field accessors for configuration validation.
;
; Every schema rule reduces to the same three questions: is the key present, is
; it the right JSON type, and is the value inside the permitted range. Doing
; that inline at each of the roughly hundred fields would be a hundred chances
; to forget the range check or to report the wrong JSON Pointer, so it is done
; once here.
;
; Each accessor pushes the key onto the error pointer BEFORE testing, and pops
; it again on success. A failure therefore leaves the pointer aimed exactly at
; the offending field.

        bits 64
        default rel

%include "asmflow.inc"
%include "json.inc"
%include "config.inc"

        extern af_json_member
        extern af_json_type
        extern af_json_get_string
        extern af_json_get_integer
        extern af_json_get_bool
        extern af_json_get_array
        extern af_json_get_object
        extern af_json_array_count
        extern af_cfg_err_fail
        extern af_cfg_err_push_key
        extern af_cfg_err_truncate
        extern af_cfg_err_depth
        extern af_cfg_enum_lookup

        section .rodata
fm_missing:  db "required key is absent", 0
fm_type:     db "value has the wrong JSON type", 0
fm_range:    db "value is outside the permitted range", 0
fm_enum:     db "value is not one of the permitted choices", 0

        section .text

; ---------------------------------------------------------------------------
; af_cfg_req_str(json_t *obj, const char *key, af_cfg_error *err,
;                const char **out_ptr, u64 *out_len) -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_req_str
af_cfg_req_str:
        AF_ENTER 32
        mov     rbx, rdi                ; object
        mov     r12, rsi                ; key
        mov     r13, rdx                ; error
        mov     r14, rcx                ; out_ptr
        mov     r15, r8                 ; out_len

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp], rax
        mov     rdi, r13
        mov     rsi, r12
        call    af_cfg_err_push_key

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r14
        mov     rcx, r15
        call    af_json_get_string
        test    rax, rax
        js      .classify
        mov     rdi, r13
        mov     rsi, [rsp]
        call    af_cfg_err_truncate
        AF_LEAVE_OK
.classify:
        cmp     rax, AF_E_NOTFOUND
        je      .missing
        mov     rdi, r13
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [fm_type]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.missing:
        mov     rdi, r13
        mov     rsi, AF_E_CFG_MISSING_KEY
        lea     rdx, [fm_missing]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_MISSING_KEY

; ---------------------------------------------------------------------------
; af_cfg_req_int(json_t *obj, const char *key, i64 min, i64 max,
;                af_cfg_error *err, i64 *out) -> af_status
;
; The range is inclusive on both ends, matching JSON Schema `minimum` and
; `maximum`.
; ---------------------------------------------------------------------------
        global af_cfg_req_int
af_cfg_req_int:
        AF_ENTER 48
        mov     rbx, rdi                ; object
        mov     r12, rsi                ; key
        mov     [rsp + 16], rdx         ; min
        mov     [rsp + 24], rcx         ; max
        mov     r13, r8                 ; error
        mov     r14, r9                 ; out

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp], rax
        mov     rdi, r13
        mov     rsi, r12
        call    af_cfg_err_push_key

        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        call    af_json_get_integer
        test    rax, rax
        js      .classify

        mov     rax, [rsp + 8]
        cmp     rax, [rsp + 16]
        jl      .range
        cmp     rax, [rsp + 24]
        jg      .range
        test    r14, r14
        jz      .ok
        mov     [r14], rax
.ok:
        mov     rdi, r13
        mov     rsi, [rsp]
        call    af_cfg_err_truncate
        AF_LEAVE_OK
.range:
        mov     rdi, r13
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [fm_range]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.classify:
        cmp     rax, AF_E_NOTFOUND
        je      .missing
        mov     rdi, r13
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [fm_type]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.missing:
        mov     rdi, r13
        mov     rsi, AF_E_CFG_MISSING_KEY
        lea     rdx, [fm_missing]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_MISSING_KEY

; ---------------------------------------------------------------------------
; af_cfg_req_bool(json_t *obj, const char *key, af_cfg_error *err, i64 *out)
;   -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_req_bool
af_cfg_req_bool:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp], rax
        mov     rdi, r13
        mov     rsi, r12
        call    af_cfg_err_push_key

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r14
        call    af_json_get_bool
        test    rax, rax
        js      .classify
        mov     rdi, r13
        mov     rsi, [rsp]
        call    af_cfg_err_truncate
        AF_LEAVE_OK
.classify:
        cmp     rax, AF_E_NOTFOUND
        je      .missing
        mov     rdi, r13
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [fm_type]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.missing:
        mov     rdi, r13
        mov     rsi, AF_E_CFG_MISSING_KEY
        lea     rdx, [fm_missing]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_MISSING_KEY

; ---------------------------------------------------------------------------
; af_cfg_opt_bool(json_t *obj, const char *key, af_cfg_error *err, i64 *out,
;                 i64 default_value) -> af_status
;
; An absent key takes the schema default. A present key of the wrong type is
; still an error: "optional" means the key may be omitted, not that a wrong
; value may be ignored.
; ---------------------------------------------------------------------------
        global af_cfg_opt_bool
af_cfg_opt_bool:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8                 ; default

        mov     rdi, rbx
        mov     rsi, r12
        xor     edx, edx
        call    af_json_member
        cmp     rax, AF_E_NOTFOUND
        je      .use_default
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        mov     rcx, r14
        call    af_cfg_req_bool
        AF_LEAVE
.use_default:
        test    r14, r14
        jz      .ok
        mov     [r14], r15
.ok:
        AF_LEAVE_OK
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_req_enum(json_t *obj, const char *key, const void *table,
;                 af_cfg_error *err, i64 *out) -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_req_enum
af_cfg_req_enum:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     [rsp + 24], rdx         ; table
        mov     r13, rcx                ; error
        mov     r14, r8                 ; out

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp], rax
        mov     rdi, r13
        mov     rsi, r12
        call    af_cfg_err_push_key

        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        lea     rcx, [rsp + 16]
        call    af_json_get_string
        test    rax, rax
        js      .classify

        mov     rdi, [rsp + 8]
        mov     rsi, [rsp + 16]
        mov     rdx, [rsp + 24]
        mov     rcx, r14
        call    af_cfg_enum_lookup
        test    rax, rax
        js      .bad_enum
        mov     rdi, r13
        mov     rsi, [rsp]
        call    af_cfg_err_truncate
        AF_LEAVE_OK
.bad_enum:
        mov     rdi, r13
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [fm_enum]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.classify:
        cmp     rax, AF_E_NOTFOUND
        je      .missing
        mov     rdi, r13
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [fm_type]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.missing:
        mov     rdi, r13
        mov     rsi, AF_E_CFG_MISSING_KEY
        lea     rdx, [fm_missing]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_MISSING_KEY

; ---------------------------------------------------------------------------
; af_cfg_req_obj(json_t *obj, const char *key, af_cfg_error *err,
;                json_t **out) -> af_status
; ---------------------------------------------------------------------------
        global af_cfg_req_obj
af_cfg_req_obj:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp], rax
        mov     rdi, r13
        mov     rsi, r12
        call    af_cfg_err_push_key

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r14
        call    af_json_get_object
        test    rax, rax
        js      .classify
        ; The pointer stays pushed: the caller is about to descend into this
        ; object and needs the segment in place.
        AF_LEAVE_OK
.classify:
        cmp     rax, AF_E_NOTFOUND
        je      .missing
        mov     rdi, r13
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [fm_type]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.missing:
        mov     rdi, r13
        mov     rsi, AF_E_CFG_MISSING_KEY
        lea     rdx, [fm_missing]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_MISSING_KEY

; ---------------------------------------------------------------------------
; af_cfg_req_arr(json_t *obj, const char *key, u64 min_items, u64 max_items,
;                af_cfg_error *err, void *out_pair) -> af_status
;
; `out_pair` receives {json_t *array, u64 count} as two consecutive words. The
; pointer segment stays pushed, as with af_cfg_req_obj.
; ---------------------------------------------------------------------------
        global af_cfg_req_arr
af_cfg_req_arr:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     [rsp + 16], rdx         ; min
        mov     [rsp + 24], rcx         ; max
        mov     r13, r8                 ; error
        mov     r14, r9                 ; out pair

        mov     rdi, r13
        call    af_cfg_err_depth
        mov     [rsp], rax
        mov     rdi, r13
        mov     rsi, r12
        call    af_cfg_err_push_key

        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r14
        lea     rcx, [r14 + 8]
        call    af_json_get_array
        test    rax, rax
        js      .classify

        mov     rax, [r14 + 8]
        cmp     rax, [rsp + 16]
        jb      .range
        cmp     rax, [rsp + 24]
        ja      .range
        AF_LEAVE_OK
.range:
        mov     rdi, r13
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [fm_range]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.classify:
        cmp     rax, AF_E_NOTFOUND
        je      .missing
        mov     rdi, r13
        mov     rsi, AF_E_CFG_SCHEMA
        lea     rdx, [fm_type]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.missing:
        mov     rdi, r13
        mov     rsi, AF_E_CFG_MISSING_KEY
        lea     rdx, [fm_missing]
        call    af_cfg_err_fail
        AF_LEAVE_ERR AF_E_CFG_MISSING_KEY

; ---------------------------------------------------------------------------
; af_cfg_opt_present(json_t *obj, const char *key) -> i64 (1 = present)
; ---------------------------------------------------------------------------
        global af_cfg_opt_present
af_cfg_opt_present:
        AF_ENTER 0
        xor     edx, edx
        call    af_json_member
        test    rax, rax
        jz      .yes
        xor     eax, eax
        AF_LEAVE
.yes:
        mov     eax, 1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_cfg_fail_here(af_cfg_error *err, const char *key, i64 code,
;                  const char *message) -> af_status
;
; Records a failure at `obj/key` without reading the value: used for the
; cross-field rules that no single accessor can express, such as "a non-loopback
; listener requires authentication".
; ---------------------------------------------------------------------------
        global af_cfg_fail_here
af_cfg_fail_here:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rdx                ; code
        mov     r13, rcx                ; message
        test    rsi, rsi
        jz      .no_key
        mov     rdi, rbx
        call    af_cfg_err_push_key
.no_key:
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        call    af_cfg_err_fail
        mov     rax, r12
        AF_LEAVE
