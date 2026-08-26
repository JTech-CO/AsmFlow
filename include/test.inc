; AsmFlow — assembly unit-test macros.
;
; Tests register themselves in a dedicated `af_test_registry` section. Because
; that name is a valid C identifier, GNU ld synthesises
; __start_af_test_registry and __stop_af_test_registry, so the runner can walk
; every test in the binary without a hand-maintained list that someone can
; forget to extend.
;
; Register discipline inside a test body: keep values in rbx and r12-r15. Every
; AF_CHECK_* macro clobbers rdi, rsi, rdx, rcx, r8, r9, r10, and r11, and must
; not be handed one of those as an operand.

%ifndef ASMFLOW_TEST_INC
%define ASMFLOW_TEST_INC

        extern af_test_check_eq
        extern af_test_check_ne
        extern af_test_check_true
        extern af_test_check_mem_eq
        extern af_test_note

; AF_TEST "name" [, local_bytes]
;
; Opens a test body. The body ends with AF_TEST_END.
;
; Each registry entry is a pair of 32-bit self-relative offsets rather than two
; absolute pointers. Absolute pointers would need a dynamic relocation in a
; position-independent executable, which either forces the section to be
; writable or produces a text relocation; self-relative offsets are resolved
; entirely at link time and keep the table read-only.
; The entry point gets an ordinary (non-context-local) name for two reasons: it
; resets NASM's local-label scope, so each test body can use plain `.loop` and
; `.done` labels without colliding with its neighbours, and it gives the symbol
; a readable name in a disassembly or a debugger. Uniqueness comes from the
; per-file AF_TEST_TAG plus a counter, so every test file must set the tag.
%assign AF_TEST_COUNTER 0

%macro AF_TEST 1-2 96
    %ifndef AF_TEST_TAG
        %error "define AF_TEST_TAG before the first AF_TEST in a file"
    %endif
    %assign AF_TEST_COUNTER AF_TEST_COUNTER + 1
    [section .rodata]
%%name: db %1, 0
    [section af_test_registry progbits align=8]
        dd %%name - $
        dd af_t_ %+ AF_TEST_TAG %+ _ %+ AF_TEST_COUNTER - $
    __?SECT?__
af_t_ %+ AF_TEST_TAG %+ _ %+ AF_TEST_COUNTER:
    AF_ENTER %2
%endmacro

%macro AF_TEST_END 0
    AF_LEAVE
%endmacro

; AF_CHECK_EQ actual, expected, "description"
;
; The two operands are copied to scratch registers before either destination is
; written, so passing r10 or r11 as `actual` still behaves.
%macro AF_CHECK_EQ 3
        mov     r10, %1
        mov     r11, %2
        mov     rdi, r10
        mov     rsi, r11
        lea     rdx, [%%desc]
        lea     rcx, [%%file]
        mov     r8, __?LINE?__
        call    af_test_check_eq
    [section .rodata]
%%desc: db %3, 0
%%file: db __?FILE?__, 0
    __?SECT?__
%endmacro

; AF_CHECK_NE actual, unexpected, "description"
%macro AF_CHECK_NE 3
        mov     r10, %1
        mov     r11, %2
        mov     rdi, r10
        mov     rsi, r11
        lea     rdx, [%%desc]
        lea     rcx, [%%file]
        mov     r8, __?LINE?__
        call    af_test_check_ne
    [section .rodata]
%%desc: db %3, 0
%%file: db __?FILE?__, 0
    __?SECT?__
%endmacro

; AF_CHECK_TRUE value, "description"
%macro AF_CHECK_TRUE 2
        mov     r10, %1
        mov     rdi, r10
        lea     rsi, [%%desc]
        lea     rdx, [%%file]
        mov     rcx, __?LINE?__
        call    af_test_check_true
    [section .rodata]
%%desc: db %2, 0
%%file: db __?FILE?__, 0
    __?SECT?__
%endmacro

; AF_CHECK_FALSE value, "description"
%macro AF_CHECK_FALSE 2
        mov     r10, %1
        test    r10, r10
        setz    r10b
        movzx   r10, r10b
        mov     rdi, r10
        lea     rsi, [%%desc]
        lea     rdx, [%%file]
        mov     rcx, __?LINE?__
        call    af_test_check_true
    [section .rodata]
%%desc: db %2, 0
%%file: db __?FILE?__, 0
    __?SECT?__
%endmacro

; AF_CHECK_OK status, "description"        - expects AF_OK
%macro AF_CHECK_OK 2
        AF_CHECK_EQ %1, AF_OK, %2
%endmacro

; AF_CHECK_ERR status, expected_code, "description"
%macro AF_CHECK_ERR 3
        AF_CHECK_EQ %1, %2, %3
%endmacro

; AF_CHECK_MEM_EQ ptr_a, ptr_b, length, "description"
%macro AF_CHECK_MEM_EQ 4
        mov     r10, %1
        mov     r11, %2
        mov     r9, %3
        mov     rdi, r10
        mov     rsi, r11
        mov     rdx, r9
        lea     rcx, [%%desc]
        lea     r8, [%%file]
        mov     r9, __?LINE?__
        call    af_test_check_mem_eq
    [section .rodata]
%%desc: db %4, 0
%%file: db __?FILE?__, 0
    __?SECT?__
%endmacro

; AF_NOTE "text"  - unconditional diagnostic line, useful while bisecting.
%macro AF_NOTE 1
        lea     rdi, [%%text]
        call    af_test_note
    [section .rodata]
%%text: db %1, 0
    __?SECT?__
%endmacro

%endif ; ASMFLOW_TEST_INC
