; AsmFlow — deterministic responsive geometry and column admission.
;
; These functions are pure: no allocation, locale, clock, terminal, or global
; mutable state.  Equal dimensions and descriptors always produce equal bytes.

        bits 64
        default rel

%include "asmflow.inc"
%include "tui.inc"

        section .text

; ---------------------------------------------------------------------------
; af_tui_layout_compute(u64 columns, u64 rows, af_tui_layout *out) -> af_status
; ---------------------------------------------------------------------------
        global af_tui_layout_compute
af_tui_layout_compute:
        AF_ENTER 0
        test    rdx, rdx
        jz      .invalid
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        cmp     rdi, AF_TUI_MAX_COLUMNS
        ja      .limit
        cmp     rsi, AF_TUI_MAX_ROWS
        ja      .limit
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        ; A fully zeroed result makes every hidden rectangle explicit.
        xor     eax, eax
        xor     ecx, ecx
.zero:
        cmp     rcx, TL_SIZE
        jae     .zeroed
        mov     [r13 + rcx], rax
        add     rcx, 8
        jmp     .zero
.zeroed:
        mov     [r13 + TL_COLS], rbx
        mov     [r13 + TL_ROWS], r12

        cmp     rbx, 60
        jb      .too_small
        cmp     r12, 16
        jb      .too_small

        ; Regions that exist in every usable mode.
        mov     qword [r13 + TL_TOP_X], 0
        mov     qword [r13 + TL_TOP_Y], 0
        mov     [r13 + TL_TOP_W], rbx
        mov     qword [r13 + TL_TOP_H], 1

        mov     rax, r12
        sub     rax, 2
        mov     qword [r13 + TL_EVENT_X], 0
        mov     [r13 + TL_EVENT_Y], rax
        mov     [r13 + TL_EVENT_W], rbx
        mov     qword [r13 + TL_EVENT_H], 1
        inc     rax
        mov     qword [r13 + TL_COMMAND_X], 0
        mov     [r13 + TL_COMMAND_Y], rax
        mov     [r13 + TL_COMMAND_W], rbx
        mov     qword [r13 + TL_COMMAND_H], 1

        cmp     r12, 20
        jbe     .narrow
        cmp     rbx, 80
        jb      .narrow
        cmp     rbx, 100
        jb      .compact
        cmp     rbx, 120
        jb      .standard
        jmp     .wide

.wide:
        mov     qword [r13 + TL_MODE], AF_TUI_LAYOUT_WIDE
        ; Wide mode reserves one-column borders around exact 18/38 side
        ; interiors.  At the required 140-column golden this leaves an
        ; 80-column main pane: 1+18+1+80+1+38+1 = 140.
        mov     qword [r13 + TL_NAV_X], 1
        mov     qword [r13 + TL_NAV_Y], 2
        mov     qword [r13 + TL_NAV_W], 18
        mov     rax, r12
        sub     rax, 4
        mov     [r13 + TL_NAV_H], rax
        mov     qword [r13 + TL_MAIN_X], 20
        mov     qword [r13 + TL_MAIN_Y], 2
        mov     rax, rbx
        sub     rax, 60
        mov     [r13 + TL_MAIN_W], rax
        mov     rax, r12
        sub     rax, 4
        mov     [r13 + TL_MAIN_H], rax
        mov     rax, rbx
        sub     rax, 39
        mov     [r13 + TL_INSPECT_X], rax
        mov     qword [r13 + TL_INSPECT_Y], 2
        mov     qword [r13 + TL_INSPECT_W], 38
        mov     rax, r12
        sub     rax, 4
        mov     [r13 + TL_INSPECT_H], rax
        jmp     .done

.standard:
        mov     qword [r13 + TL_MODE], AF_TUI_LAYOUT_STANDARD
        mov     qword [r13 + TL_FLAGS], (AF_TUI_LF_NAV_TABS | AF_TUI_LF_INSPECT_OVERLAY)
        jmp     .tabs

.compact:
        mov     qword [r13 + TL_MODE], AF_TUI_LAYOUT_COMPACT
        mov     qword [r13 + TL_FLAGS], (AF_TUI_LF_NAV_TABS | AF_TUI_LF_INSPECT_OVERLAY)
        jmp     .tabs

.narrow:
        mov     qword [r13 + TL_MODE], AF_TUI_LAYOUT_NARROW
        mov     qword [r13 + TL_FLAGS], (AF_TUI_LF_NAV_TABS | AF_TUI_LF_INSPECT_OVERLAY | AF_TUI_LF_DRILLDOWN)
.tabs:
        mov     qword [r13 + TL_NAV_X], 0
        mov     qword [r13 + TL_NAV_Y], 1
        mov     [r13 + TL_NAV_W], rbx
        mov     qword [r13 + TL_NAV_H], 1
        mov     qword [r13 + TL_MAIN_X], 0
        mov     qword [r13 + TL_MAIN_Y], 2
        mov     [r13 + TL_MAIN_W], rbx
        mov     rax, r12
        sub     rax, 4
        mov     [r13 + TL_MAIN_H], rax
        jmp     .done

.too_small:
        mov     qword [r13 + TL_MODE], AF_TUI_LAYOUT_TOO_SMALL
        mov     qword [r13 + TL_FLAGS], AF_TUI_LF_ENLARGE
        mov     qword [r13 + TL_MAIN_X], 0
        mov     qword [r13 + TL_MAIN_Y], 0
        mov     [r13 + TL_MAIN_W], rbx
        mov     [r13 + TL_MAIN_H], r12
.done:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

; ---------------------------------------------------------------------------
; af_tui_columns_fit(columns, count, available, spacing, out_fit) -> af_status
;
; Priority-0 columns are mandatory.  Remaining columns form a deterministic
; priority/source-order prefix: once one does not fit, lower priority columns
; cannot leapfrog it.  The resulting width never exceeds `available`.
; ---------------------------------------------------------------------------
        global af_tui_columns_fit
af_tui_columns_fit:
        AF_ENTER 64
        test    r8, r8
        jz      .invalid
        cmp     rsi, 64
        ja      .limit
        test    rsi, rsi
        jz      .empty
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8

        ; Validate the entire descriptor set before producing output.
        xor     ecx, ecx
.validate:
        cmp     rcx, r12
        jae     .validated
        mov     rax, rcx
        imul    rax, TCD_SIZE
        add     rax, rbx
        cmp     qword [rax + TCD_PRIORITY], 3
        ja      .invalid
        cmp     qword [rax + TCD_MIN_WIDTH], 0
        je      .invalid
        mov     rdx, [rax + TCD_MAX_WIDTH]
        cmp     rdx, [rax + TCD_MIN_WIDTH]
        jb      .invalid
        inc     rcx
        jmp     .validate
.validated:
        mov     qword [rsp], 0                 ; mask
        mov     qword [rsp + 8], 0             ; width
        mov     qword [rsp + 16], 0            ; visible count
        xor     r9d, r9d                       ; priority being admitted
.priority:
        cmp     r9, 4
        jae     .commit
        xor     r10d, r10d                     ; column index
.scan:
        cmp     r10, r12
        jae     .next_priority
        mov     rax, r10
        imul    rax, TCD_SIZE
        add     rax, rbx
        cmp     [rax + TCD_PRIORITY], r9
        jne     .next
        mov     rdx, [rsp + 8]
        cmp     qword [rsp + 16], 0
        je      .no_spacing
        add     rdx, r14
        jc      .overflow
.no_spacing:
        add     rdx, [rax + TCD_MIN_WIDTH]
        jc      .overflow
        cmp     rdx, r13
        ja      .does_not_fit
        mov     [rsp + 8], rdx
        mov     rcx, r10
        mov     rax, 1
        shl     rax, cl
        or      [rsp], rax
        inc     qword [rsp + 16]
.next:
        inc     r10
        jmp     .scan
.does_not_fit:
        test    r9, r9
        jz      .limit                         ; mandatory column cannot fit
        jmp     .commit                        ; never admit a lower priority
.next_priority:
        inc     r9
        jmp     .priority
.commit:
        mov     rax, [rsp]
        mov     [r15 + TCF_MASK], rax
        mov     rax, [rsp + 8]
        mov     [r15 + TCF_WIDTH], rax
        AF_LEAVE_OK
.empty:
        mov     qword [r8 + TCF_MASK], 0
        mov     qword [r8 + TCF_WIDTH], 0
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.overflow:
        AF_LEAVE_ERR AF_E_OVERFLOW
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

        global af_tui_layout_struct_size
af_tui_layout_struct_size:
        mov     eax, TL_SIZE
        ret

        global af_tui_column_struct_size
af_tui_column_struct_size:
        mov     eax, TCD_SIZE
        ret
