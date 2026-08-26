; AsmFlow — System V AMD64 ABI discipline macros.
;
; Ownership: this file defines no data. It only provides prologue/epilogue and
; call-site macros that make invariants 3, 4, and 5 of AGENTS.md true by
; construction rather than by per-function review.
;
; Invariant 4 (16-byte stack alignment before a C call) and invariant 5
; (callee-saved registers preserved) are enforced by using a single uniform
; frame shape for every non-trivial exported function:
;
;   entry:            rsp % 16 == 8      (call pushed the return address)
;   push rbp          rsp % 16 == 0
;   push rbx/r12..r15 rsp % 16 == 8      (5 more pushes = 40 bytes)
;   sub rsp, K        rsp % 16 == 0      when K % 16 == 8
;
; AF_ENTER therefore always subtracts `align16(locals) + 8`, which keeps rsp
; 16-byte aligned for the whole body. Locals are addressed as [rsp + n] because
; rsp never moves inside a function that uses these macros.
;
; Frame layout after AF_ENTER n:
;
;   [rbp +  0]  saved rbp
;   [rbp -  8]  saved rbx
;   [rbp - 16]  saved r12
;   [rbp - 24]  saved r13
;   [rbp - 32]  saved r14
;   [rbp - 40]  saved r15
;   [rsp + 0 .. rsp + n)   caller-declared locals
;   (up to 8 bytes of alignment padding above the locals)

%ifndef ASMFLOW_ABI_INC
%define ASMFLOW_ABI_INC

%define AF_FRAME_SAVED_BYTES 40

; AF_ENTER [local_bytes]
;
; Establishes the uniform frame. `local_bytes` may be 0. Every callee-saved
; register is preserved unconditionally so that no function can violate the ABI
; by forgetting one; the cost is five pushes and five pops.
%macro AF_ENTER 0-1 0
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, ((((%1) + 15) & ~15) + 8)
%endmacro

; AF_LEAVE
;
; Restores callee-saved registers and returns. Does not touch rax/rdx so a
; return value already in place survives.
%macro AF_LEAVE 0
    lea     rsp, [rbp - AF_FRAME_SAVED_BYTES]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
%endmacro

; AF_LEAVE_OK / AF_LEAVE_ERR code
;
; Convenience wrappers for the af_status return convention (see errors.inc).
%macro AF_LEAVE_OK 0
    xor     eax, eax
    AF_LEAVE
%endmacro

%macro AF_LEAVE_ERR 1
    mov     rax, %1
    AF_LEAVE
%endmacro

; AF_CCALL target
;
; Calls an external C symbol through the PLT with the variadic-ABI vector
; register count cleared. Use AF_CCALL_V for variadic callees that receive
; floating-point arguments.
%macro AF_CCALL 1
    xor     eax, eax
    call    %1 wrt ..plt
%endmacro

; AF_CCALL_V xmm_count, target
%macro AF_CCALL_V 2
    mov     eax, %1
    call    %2 wrt ..plt
%endmacro

; AF_LEA_STR reg, label
;
; RIP-relative address of a local .rodata label. `default rel` is assumed.
%macro AF_LEA_STR 2
    lea     %1, [%2]
%endmacro

; AF_STATIC_ASSERT expr, message
%macro AF_STATIC_ASSERT 2
    %if (%1) == 0
        %error %2
    %endif
%endmacro

; ---------------------------------------------------------------------------
; Structure-definition helper.
;
; AF_STRUCT name
;   AF_FIELD field, bytes
; AF_STRUCT_END
;
; Produces `name_field` byte offsets and `name_size` (rounded to 8) so that
; assembly and the C ABI manifest in src/ffi can be diffed mechanically.
; ---------------------------------------------------------------------------
%macro AF_STRUCT 1
    %push af_struct
    %define %$structname %1
    %assign %$offset 0
%endmacro

%macro AF_FIELD 2
    %[%$structname]_%[%1] equ %$offset
    %assign %$offset %$offset + (%2)
%endmacro

%macro AF_STRUCT_END 0
    %[%$structname]_size equ ((%$offset + 7) & ~7)
    %pop
%endmacro

%endif ; ASMFLOW_ABI_INC
