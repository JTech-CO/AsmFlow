; AsmFlow — debug assertions.
;
; Assertions state facts the surrounding code depends on. They compile away
; entirely in release builds, so they must never be the only check protecting a
; boundary that untrusted input can reach: those get explicit af_status
; validation that is present in every build.
;
; All assertion macros clobber rdi/rsi/rdx/rcx and the flags, but only on the
; failing path, which does not return.

%ifndef ASMFLOW_ASSERT_INC
%define ASMFLOW_ASSERT_INC

%ifdef AF_DEBUG

%macro AF_ASSERT_STRINGS 1
    [section .rodata]
%%msg:  db %1, 0
%%file: db __?FILE?__, 0
    __?SECT?__
%endmacro

; AF_ASSERT_NZ value, "message"
%macro AF_ASSERT_NZ 2
    test    %1, %1
    jnz     %%ok
    lea     rdi, [%%msg]
    lea     rsi, [%%file]
    mov     rdx, __?LINE?__
    xor     ecx, ecx
    call    af_panic
%%ok:
    AF_ASSERT_STRINGS %2
%endmacro

; AF_ASSERT_Z value, "message"
%macro AF_ASSERT_Z 2
    test    %1, %1
    jz      %%ok
    lea     rdi, [%%msg]
    lea     rsi, [%%file]
    mov     rdx, __?LINE?__
    xor     ecx, ecx
    call    af_panic
%%ok:
    AF_ASSERT_STRINGS %2
%endmacro

; AF_ASSERT_EQ actual, expected, "message"
; `expected` is reported as the panic context so a failure names the value it
; wanted rather than only the source location.
%macro AF_ASSERT_EQ 3
    cmp     %1, %2
    je      %%ok
    mov     rcx, %1
    lea     rdi, [%%msg]
    lea     rsi, [%%file]
    mov     rdx, __?LINE?__
    call    af_panic
%%ok:
    AF_ASSERT_STRINGS %3
%endmacro

; AF_ASSERT_BELOW value, bound, "message"
%macro AF_ASSERT_BELOW 3
    cmp     %1, %2
    jb      %%ok
    mov     rcx, %1
    lea     rdi, [%%msg]
    lea     rsi, [%%file]
    mov     rdx, __?LINE?__
    call    af_panic
%%ok:
    AF_ASSERT_STRINGS %3
%endmacro

; AF_UNREACHABLE "message"
%macro AF_UNREACHABLE 1
    lea     rdi, [%%msg]
    lea     rsi, [%%file]
    mov     rdx, __?LINE?__
    xor     ecx, ecx
    call    af_panic
    AF_ASSERT_STRINGS %1
%endmacro

%else ; release

%macro AF_ASSERT_NZ 2
%endmacro
%macro AF_ASSERT_Z 2
%endmacro
%macro AF_ASSERT_EQ 3
%endmacro
%macro AF_ASSERT_BELOW 3
%endmacro
%macro AF_UNREACHABLE 1
    ud2
%endmacro

%endif

%endif ; ASMFLOW_ASSERT_INC
