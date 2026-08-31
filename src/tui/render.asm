; AsmFlow — deterministic high-level text layout renderer.
;
; `af_tui_render_screen` is shared by interactive presentation and
; `--dump-layout`: it consumes the same bounded canvas, screen descriptors, and
; fixed-size BORROWED model.  It has no clock, socket, ncurses, allocation, or
; mutable global state.  A NULL model renders a safe disconnected diagnostic.

        bits 64
        default rel

%include "asmflow.inc"
%include "tui.inc"

        extern af_tui_canvas_clear
        extern af_tui_canvas_put_ascii
        extern af_tui_canvas_put_utf8
        extern af_tui_layout_compute
        extern af_tui_screen_descriptor
        extern af_tui_screen_columns_fit
        extern af_tui_render_overview
        extern af_u64_to_dec

        section .rodata

r_product:          db "AsmFlow "
r_product_len equ $ - r_product
r_connected:        db "CONNECTED"
r_connected_len equ $ - r_connected
r_stale:            db "STALE"
r_stale_len equ $ - r_stale
r_disconnected:     db "DISCONNECTED"
r_disconnected_len equ $ - r_disconnected
r_cfg:              db " cfg:"
r_cfg_len equ $ - r_cfg
r_req:              db " req:"
r_req_len equ $ - r_req
r_mcp:              db " mcp:"
r_mcp_len equ $ - r_mcp
r_slash:            db "/"
r_slash_len equ $ - r_slash
r_colon:            db ":"
r_colon_len equ $ - r_colon
r_selected:         db ">"
r_unselected:       db " "
r_dash:             db "-"
r_detail:           db "DETAIL"
r_detail_len equ $ - r_detail
r_no_selection:     db "No selection."
r_no_selection_len equ $ - r_no_selection
r_empty:            db "No data in the current snapshot."
r_empty_len equ $ - r_empty
r_ready:            db "Ready."
r_ready_len equ $ - r_ready
r_stale_event:      db "Snapshot is stale. Press r to retry."
r_stale_event_len equ $ - r_stale_event
r_disconnected_event:
        db "Disconnected. Press r to retry or q to exit."
r_disconnected_event_len equ $ - r_disconnected_event
r_commands:
        db "j/k rows  r refresh  : commands  ? help  q quit"
r_commands_len equ $ - r_commands
r_small_1:          db "AsmFlow: terminal enlargement required (minimum 60x16)."
r_small_1_len equ $ - r_small_1
r_small_2:          db "Use asmflowctl --json while the TUI is unavailable."
r_small_2_len equ $ - r_small_2

        section .text

; Private wrappers keep the six-register canvas ABI out of rendering code.
; _af_tui_render_put_ascii(c,x,y,p,n) -> af_status
_af_tui_render_put_ascii:
        AF_ENTER 16
        lea     r9, [rsp]
        call    af_tui_canvas_put_ascii
        AF_LEAVE

; _af_tui_render_put_utf8(c,x,y,p,n) -> af_status
_af_tui_render_put_utf8:
        AF_ENTER 16
        lea     r9, [rsp]
        call    af_tui_canvas_put_utf8
        AF_LEAVE

; _af_tui_render_put_u64(c,x,y,value,out_columns) -> af_status
_af_tui_render_put_u64:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, r8
        mov     rdi, rcx
        lea     rsi, [rsp]
        mov     edx, 20
        lea     rcx, [rsp + 24]
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        lea     rcx, [rsp]
        mov     r8, [rsp + 24]
        mov     r9, r14
        call    af_tui_canvas_put_ascii
.done:
        AF_LEAVE

; Private: connection state -> rax STATIC bytes, rdx length.
_af_tui_render_connection:
        cmp     rdi, AF_TUI_CONN_CONNECTED
        je      .connected
        cmp     rdi, AF_TUI_CONN_STALE
        je      .stale
        lea     rax, [r_disconnected]
        mov     edx, r_disconnected_len
        ret
.connected:
        lea     rax, [r_connected]
        mov     edx, r_connected_len
        ret
.stale:
        lea     rax, [r_stale]
        mov     edx, r_stale_len
        ret

; ---------------------------------------------------------------------------
; _af_tui_render_navigation(canvas, layout, screen_id) -> af_status
; ---------------------------------------------------------------------------
_af_tui_render_navigation:
        AF_ENTER 80
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, 1
        mov     rax, [r12 + TL_NAV_X]
        mov     [rsp + 16], rax                ; current/tab x
        add     rax, [r12 + TL_NAV_W]
        mov     [rsp + 40], rax                ; nav right edge
.screen:
        cmp     r14, AF_TUI_SCREEN_COUNT
        ja      .done
        mov     rdi, r14
        call    af_tui_screen_descriptor
        test    rax, rax
        jz      .invalid
        mov     [rsp + 32], rax
        mov     rcx, [rax + TSD_TITLE]
        mov     [rsp + 48], rcx
        mov     rcx, [rax + TSD_TITLE_LEN]
        mov     [rsp + 24], rcx

        test    qword [r12 + TL_FLAGS], AF_TUI_LF_NAV_TABS
        jnz     .tabs

        mov     rax, r14
        dec     rax
        add     rax, [r12 + TL_NAV_Y]
        mov     [rsp + 56], rax                ; row y
        mov     rcx, [r12 + TL_NAV_Y]
        add     rcx, [r12 + TL_NAV_H]
        cmp     rax, rcx
        jae     .done
        mov     byte [rsp], ' '
        cmp     r14, r13
        jne     .vertical_marker
        mov     byte [rsp], '>'
.vertical_marker:
        mov     rdi, rbx
        mov     rsi, [r12 + TL_NAV_X]
        mov     rdx, [rsp + 56]
        lea     rcx, [rsp]
        mov     r8d, 1
        call    _af_tui_render_put_ascii
        mov     rax, [rsp + 32]
        mov     rcx, [rax + TSD_KEY]
        mov     [rsp + 1], cl
        mov     rdi, rbx
        mov     rsi, [r12 + TL_NAV_X]
        add     rsi, 2
        mov     rdx, [rsp + 56]
        lea     rcx, [rsp + 1]
        mov     r8d, 1
        call    _af_tui_render_put_ascii
        mov     rdi, rbx
        mov     rsi, [r12 + TL_NAV_X]
        add     rsi, 4
        mov     rdx, [rsp + 56]
        mov     rcx, [rsp + 48]
        mov     r8, [rsp + 24]
        mov     rax, [r12 + TL_NAV_W]
        cmp     rax, 4
        jbe     .next
        sub     rax, 4
        cmp     r8, rax
        cmova   r8, rax
        call    _af_tui_render_put_utf8
        jmp     .next

.tabs:
        mov     rax, [rsp + 16]
        cmp     rax, [rsp + 40]
        jae     .done
        mov     byte [rsp], ' '
        cmp     r14, r13
        jne     .tab_marker
        mov     byte [rsp], '>'
.tab_marker:
        mov     rdi, rbx
        mov     rsi, [rsp + 16]
        mov     rdx, [r12 + TL_NAV_Y]
        lea     rcx, [rsp]
        mov     r8d, 1
        call    _af_tui_render_put_ascii
        mov     rax, [rsp + 32]
        mov     rcx, [rax + TSD_KEY]
        mov     [rsp + 1], cl
        mov     rdi, rbx
        mov     rsi, [rsp + 16]
        inc     rsi
        mov     rdx, [r12 + TL_NAV_Y]
        lea     rcx, [rsp + 1]
        mov     r8d, 1
        call    _af_tui_render_put_ascii
        mov     rdi, rbx
        mov     rsi, [rsp + 16]
        add     rsi, 2
        mov     rdx, [r12 + TL_NAV_Y]
        lea     rcx, [r_colon]
        mov     r8d, r_colon_len
        call    _af_tui_render_put_ascii
        mov     rsi, [rsp + 16]
        add     rsi, 3
        mov     rax, [rsp + 40]
        sub     rax, rsi
        mov     r8, [rsp + 24]
        cmp     r8, rax
        cmova   r8, rax
        test    r8, r8
        jz      .done
        mov     rdi, rbx
        mov     rdx, [r12 + TL_NAV_Y]
        mov     rcx, [rsp + 48]
        call    _af_tui_render_put_utf8
        mov     rax, [rsp + 24]
        add     rax, 4
        add     [rsp + 16], rax
.next:
        inc     r14
        jmp     .screen
.done:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INTERNAL

; ---------------------------------------------------------------------------
; af_tui_render_screen(canvas, screen_id, model_or_null) -> af_status
; ---------------------------------------------------------------------------
        global af_tui_render_screen
af_tui_render_screen:
        AF_ENTER 400
        test    rdi, rdi
        jz      .invalid
        mov     [rsp + 240], rdi               ; canvas
        mov     [rsp + 248], rsi               ; screen id
        mov     [rsp + 256], rdx               ; model, nullable
        mov     rdi, rsi
        call    af_tui_screen_descriptor
        test    rax, rax
        jz      .not_found
        mov     [rsp + 264], rax               ; screen descriptor

        mov     rbx, [rsp + 240]
        mov     rdi, [rbx + TC_WIDTH]
        mov     rsi, [rbx + TC_HEIGHT]
        lea     rdx, [rsp]
        call    af_tui_layout_compute
        test    rax, rax
        js      .return
        mov     rdi, rbx
        mov     esi, ' '
        call    af_tui_canvas_clear
        test    rax, rax
        js      .return

        cmp     qword [rsp + TL_MODE], AF_TUI_LAYOUT_TOO_SMALL
        je      .too_small

        ; Validate the bounded model once before dereferencing its children.
        mov     r12, [rsp + 256]
        mov     qword [rsp + 272], AF_TUI_CONN_DISCONNECTED
        mov     qword [rsp + 280], -1          ; selected row
        mov     qword [rsp + 288], 0           ; row count
        mov     qword [rsp + 296], 0           ; rows
        test    r12, r12
        jz      .model_ready
        cmp     qword [r12 + TM_CONNECTION], AF_TUI_CONN_DISCONNECTED
        ja      .invalid
        mov     rax, [r12 + TM_UTC_LEN]
        cmp     rax, AF_TUI_TEXT_MAX_BYTES
        ja      .limit
        test    rax, rax
        jz      .utc_ok
        cmp     qword [r12 + TM_UTC_PTR], 0
        je      .invalid
.utc_ok:
        mov     rax, [r12 + TM_DETAIL_TITLE_LEN]
        cmp     rax, AF_TUI_TEXT_MAX_BYTES
        ja      .limit
        test    rax, rax
        jz      .detail_title_ok
        cmp     qword [r12 + TM_DETAIL_TITLE_PTR], 0
        je      .invalid
.detail_title_ok:
        mov     rax, [r12 + TM_DETAIL_BODY_LEN]
        cmp     rax, AF_TUI_TEXT_MAX_BYTES
        ja      .limit
        test    rax, rax
        jz      .detail_body_ok
        cmp     qword [r12 + TM_DETAIL_BODY_PTR], 0
        je      .invalid
.detail_body_ok:
        mov     rax, [r12 + TM_EVENT_LEN]
        cmp     rax, AF_TUI_TEXT_MAX_BYTES
        ja      .limit
        test    rax, rax
        jz      .event_ok
        cmp     qword [r12 + TM_EVENT_PTR], 0
        je      .invalid
.event_ok:
        mov     rax, [r12 + TM_ROW_COUNT]
        cmp     rax, AF_TUI_MODEL_MAX_ROWS
        ja      .limit
        test    rax, rax
        jz      .rows_ok
        cmp     qword [r12 + TM_ROWS], 0
        je      .invalid
.rows_ok:
        mov     rax, [r12 + TM_CONNECTION]
        mov     [rsp + 272], rax
        mov     rax, [r12 + TM_SELECTED_INDEX]
        mov     [rsp + 280], rax
        mov     rax, [r12 + TM_ROW_COUNT]
        mov     [rsp + 288], rax
        mov     rax, [r12 + TM_ROWS]
        mov     [rsp + 296], rax
.model_ready:
        cmp     qword [rsp + 248], AF_TUI_SCREEN_OVERVIEW
        jne     .generic_render
        test    r12, r12
        jz      .generic_render
        cmp     qword [r12 + TM_OVERVIEW], 0
        je      .generic_render
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, r12
        call    af_tui_render_overview
        jmp     .return

.generic_render:

        ; Top bar, assembled left-to-right so even 20-digit counters cannot
        ; overwrite a following field.
        mov     qword [rsp + 320], 0            ; current x
        mov     rdi, rbx
        xor     esi, esi
        xor     edx, edx
        lea     rcx, [r_product]
        mov     r8d, r_product_len
        call    _af_tui_render_put_ascii
        add     qword [rsp + 320], r_product_len
        mov     rdi, [rsp + 272]
        call    _af_tui_render_connection
        mov     [rsp + 328], rdx
        mov     rdi, rbx
        mov     rsi, [rsp + 320]
        xor     edx, edx
        mov     rcx, rax
        mov     r8, [rsp + 328]
        call    _af_tui_render_put_ascii
        mov     rax, [rsp + 328]
        add     [rsp + 320], rax

        mov     rdi, rbx
        mov     rsi, [rsp + 320]
        xor     edx, edx
        lea     rcx, [r_cfg]
        mov     r8d, r_cfg_len
        call    _af_tui_render_put_ascii
        add     qword [rsp + 320], r_cfg_len
        xor     ecx, ecx
        test    r12, r12
        jz      .top_revision
        mov     rcx, [r12 + TM_REVISION]
.top_revision:
        mov     rdi, rbx
        mov     rsi, [rsp + 320]
        xor     edx, edx
        lea     r8, [rsp + 376]
        call    _af_tui_render_put_u64
        mov     rax, [rsp + 376]
        add     [rsp + 320], rax

        cmp     qword [rbx + TC_WIDTH], 80
        jb      .top_clock
        mov     rdi, rbx
        mov     rsi, [rsp + 320]
        xor     edx, edx
        lea     rcx, [r_req]
        mov     r8d, r_req_len
        call    _af_tui_render_put_ascii
        add     qword [rsp + 320], r_req_len
        xor     ecx, ecx
        test    r12, r12
        jz      .top_active
        mov     rcx, [r12 + TM_ACTIVE_REQUESTS]
.top_active:
        mov     rdi, rbx
        mov     rsi, [rsp + 320]
        xor     edx, edx
        lea     r8, [rsp + 376]
        call    _af_tui_render_put_u64
        mov     rax, [rsp + 376]
        add     [rsp + 320], rax
        mov     rdi, rbx
        mov     rsi, [rsp + 320]
        xor     edx, edx
        lea     rcx, [r_mcp]
        mov     r8d, r_mcp_len
        call    _af_tui_render_put_ascii
        add     qword [rsp + 320], r_mcp_len
        xor     ecx, ecx
        test    r12, r12
        jz      .top_mcp_running
        mov     rcx, [r12 + TM_MCP_RUNNING]
.top_mcp_running:
        mov     rdi, rbx
        mov     rsi, [rsp + 320]
        xor     edx, edx
        lea     r8, [rsp + 376]
        call    _af_tui_render_put_u64
        mov     rax, [rsp + 376]
        add     [rsp + 320], rax
        mov     rdi, rbx
        mov     rsi, [rsp + 320]
        xor     edx, edx
        lea     rcx, [r_slash]
        mov     r8d, r_slash_len
        call    _af_tui_render_put_ascii
        inc     qword [rsp + 320]
        xor     ecx, ecx
        test    r12, r12
        jz      .top_mcp_total
        mov     rcx, [r12 + TM_MCP_TOTAL]
.top_mcp_total:
        mov     rdi, rbx
        mov     rsi, [rsp + 320]
        xor     edx, edx
        lea     r8, [rsp + 376]
        call    _af_tui_render_put_u64

.top_clock:
        cmp     qword [rbx + TC_WIDTH], 100
        jb      .navigation
        test    r12, r12
        jz      .navigation
        mov     r8, [r12 + TM_UTC_LEN]
        test    r8, r8
        jz      .navigation
        cmp     r8, 24
        cmova   r8, qword [rsp + 368]          ; overwritten below; avoid long clock
        ; The branch above needs a deterministic cap without memory tricks.
        cmp     r8, 24
        jbe     .clock_capped
        mov     r8d, 24
.clock_capped:
        mov     rsi, [rbx + TC_WIDTH]
        sub     rsi, r8
        mov     rdi, rbx
        xor     edx, edx
        mov     rcx, [r12 + TM_UTC_PTR]
        call    _af_tui_render_put_utf8

.navigation:
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, [rsp + 248]
        call    _af_tui_render_navigation
        test    rax, rax
        js      .return

        ; Screen title.
        mov     r15, [rsp + 264]
        mov     rdi, rbx
        mov     rsi, [rsp + TL_MAIN_X]
        mov     rdx, [rsp + TL_MAIN_Y]
        mov     rcx, [r15 + TSD_TITLE]
        mov     r8, [r15 + TSD_TITLE_LEN]
        call    _af_tui_render_put_ascii

        ; Reserve two columns for the stable selection cursor.
        mov     rax, [rsp + TL_MAIN_W]
        cmp     rax, 2
        jbe     .invalid
        sub     rax, 2
        mov     [rsp + 368], rax
        mov     rdi, [rsp + 248]
        mov     rsi, rax
        lea     rdx, [rsp + 224]
        call    af_tui_screen_columns_fit
        test    rax, rax
        js      .return
        ; Provider LAST_ERROR is a wide-mode drill-down field.  A standard
        ; layout has more raw table width than the bordered wide main pane, so
        ; the monotonic fitter alone cannot express this layout-class policy.
        cmp     qword [rsp + 248], AF_TUI_SCREEN_PROVIDERS
        jne     .columns_ready
        cmp     qword [rsp + TL_MODE], AF_TUI_LAYOUT_WIDE
        je      .columns_ready
        and     qword [rsp + 224 + TCF_MASK], ~(1 << 6)
.columns_ready:
        mov     rax, [r15 + TSD_COLUMNS]
        mov     [rsp + 304], rax
        mov     rax, [r15 + TSD_COLUMN_COUNT]
        mov     [rsp + 312], rax

        ; Header row.
        mov     rax, [rsp + TL_MAIN_X]
        add     rax, 2
        mov     [rsp + 320], rax
        mov     qword [rsp + 344], 0
.header_column:
        mov     r14, [rsp + 344]
        cmp     r14, [rsp + 312]
        jae     .rows_begin
        mov     rcx, r14
        mov     rax, 1
        shl     rax, cl
        test    [rsp + 224 + TCF_MASK], rax
        jz      .header_next
        mov     rax, r14
        imul    rax, TCD_SIZE
        add     rax, [rsp + 304]
        mov     [rsp + 360], rax
        mov     r8, [rax + TCD_LABEL_LEN]
        cmp     r8, [rax + TCD_MIN_WIDTH]
        cmova   r8, [rax + TCD_MIN_WIDTH]
        mov     rdi, rbx
        mov     rsi, [rsp + 320]
        mov     rdx, [rsp + TL_MAIN_Y]
        add     rdx, 2
        mov     rcx, [rax + TCD_LABEL]
        call    _af_tui_render_put_ascii
        mov     rax, [rsp + 360]
        mov     rcx, [rax + TCD_MIN_WIDTH]
        inc     rcx
        add     [rsp + 320], rcx
.header_next:
        inc     qword [rsp + 344]
        jmp     .header_column

.rows_begin:
        cmp     qword [rsp + 288], 0
        je      .empty_state
        mov     rax, [rsp + TL_MAIN_H]
        cmp     rax, 3
        jbe     .detail
        sub     rax, 3
        cmp     rax, [rsp + 288]
        cmova   rax, [rsp + 288]
        mov     [rsp + 336], rax               ; displayed count (temporary)
        mov     qword [rsp + 328], 0            ; row index
.row:
        mov     r14, [rsp + 328]
        cmp     r14, [rsp + 336]
        jae     .detail
        mov     rax, r14
        imul    rax, TR_SIZE
        add     rax, [rsp + 296]
        mov     [rsp + 352], rax
        cmp     qword [rax + TR_CELL_COUNT], AF_TUI_ROW_MAX_CELLS
        ja      .limit
        cmp     qword [rax + TR_CELL_COUNT], 0
        je      .row_cells_ok
        cmp     qword [rax + TR_CELLS], 0
        je      .invalid
.row_cells_ok:
        mov     rax, [rsp + TL_MAIN_Y]
        add     rax, 3
        add     rax, r14
        mov     [rsp + 344], rax               ; row y
        lea     rcx, [r_unselected]
        cmp     r14, [rsp + 280]
        jne     .row_marker
        lea     rcx, [r_selected]
.row_marker:
        mov     rdi, rbx
        mov     rsi, [rsp + TL_MAIN_X]
        mov     rdx, [rsp + 344]
        mov     r8d, 1
        call    _af_tui_render_put_ascii

        mov     rax, [rsp + TL_MAIN_X]
        add     rax, 2
        mov     [rsp + 320], rax
        mov     qword [rsp + 360], 0            ; column index
.row_column:
        mov     r14, [rsp + 360]
        cmp     r14, [rsp + 312]
        jae     .row_next
        mov     rcx, r14
        mov     rax, 1
        shl     rax, cl
        test    [rsp + 224 + TCF_MASK], rax
        jz      .row_column_next
        mov     rax, r14
        imul    rax, TCD_SIZE
        add     rax, [rsp + 304]
        mov     [rsp + 368], rax               ; current column descriptor
        lea     rcx, [r_dash]
        mov     r8d, 1
        mov     rax, [rsp + 352]
        cmp     r14, [rax + TR_CELL_COUNT]
        jae     .cell_ready
        mov     rax, [rax + TR_CELLS]
        mov     rdx, r14
        imul    rdx, TT_SIZE
        add     rax, rdx
        mov     r8, [rax + TT_LEN]
        cmp     r8, AF_TUI_TEXT_MAX_BYTES
        ja      .limit
        test    r8, r8
        jz      .cell_ready
        mov     rcx, [rax + TT_PTR]
        test    rcx, rcx
        jz      .invalid
.cell_ready:
        mov     rax, [rsp + 368]
        cmp     r8, [rax + TCD_MIN_WIDTH]
        cmova   r8, [rax + TCD_MIN_WIDTH]
        mov     rsi, [rsp + 320]
        cmp     qword [rax + TCD_ALIGN], AF_TUI_ALIGN_RIGHT
        jne     .cell_positioned
        mov     rdx, [rax + TCD_MIN_WIDTH]
        sub     rdx, r8
        add     rsi, rdx
.cell_positioned:
        mov     rdi, rbx
        mov     rdx, [rsp + 344]
        call    _af_tui_render_put_utf8
        mov     rax, [rsp + 368]
        mov     rcx, [rax + TCD_MIN_WIDTH]
        inc     rcx
        add     [rsp + 320], rcx
.row_column_next:
        inc     qword [rsp + 360]
        jmp     .row_column
.row_next:
        inc     qword [rsp + 328]
        jmp     .row

.empty_state:
        mov     rdi, rbx
        mov     rsi, [rsp + TL_MAIN_X]
        add     rsi, 2
        mov     rdx, [rsp + TL_MAIN_Y]
        add     rdx, 3
        lea     rcx, [r_empty]
        mov     r8d, r_empty_len
        call    _af_tui_render_put_ascii

.detail:
        cmp     qword [rsp + TL_INSPECT_W], 0
        je      .event_line
        mov     rdi, rbx
        mov     rsi, [rsp + TL_INSPECT_X]
        inc     rsi
        mov     rdx, [rsp + TL_INSPECT_Y]
        lea     rcx, [r_detail]
        mov     r8d, r_detail_len
        call    _af_tui_render_put_ascii
        lea     rcx, [r_no_selection]
        mov     r8d, r_no_selection_len
        test    r12, r12
        jz      .detail_title
        cmp     qword [r12 + TM_DETAIL_TITLE_LEN], 0
        je      .detail_title
        mov     rcx, [r12 + TM_DETAIL_TITLE_PTR]
        mov     r8, [r12 + TM_DETAIL_TITLE_LEN]
.detail_title:
        mov     rax, [rsp + TL_INSPECT_W]
        cmp     rax, 2
        jbe     .event_line
        sub     rax, 2
        cmp     r8, rax
        cmova   r8, rax
        mov     rdi, rbx
        mov     rsi, [rsp + TL_INSPECT_X]
        inc     rsi
        mov     rdx, [rsp + TL_INSPECT_Y]
        add     rdx, 2
        call    _af_tui_render_put_utf8
        test    r12, r12
        jz      .event_line
        mov     r8, [r12 + TM_DETAIL_BODY_LEN]
        test    r8, r8
        jz      .event_line
        mov     rax, [rsp + TL_INSPECT_W]
        sub     rax, 2
        cmp     r8, rax
        cmova   r8, rax
        mov     rdi, rbx
        mov     rsi, [rsp + TL_INSPECT_X]
        inc     rsi
        mov     rdx, [rsp + TL_INSPECT_Y]
        add     rdx, 4
        mov     rcx, [r12 + TM_DETAIL_BODY_PTR]
        call    _af_tui_render_put_utf8

.event_line:
        lea     rcx, [r_ready]
        mov     r8d, r_ready_len
        cmp     qword [rsp + 272], AF_TUI_CONN_STALE
        jne     .event_disconnected
        lea     rcx, [r_stale_event]
        mov     r8d, r_stale_event_len
        jmp     .event_model
.event_disconnected:
        cmp     qword [rsp + 272], AF_TUI_CONN_DISCONNECTED
        jne     .event_model
        lea     rcx, [r_disconnected_event]
        mov     r8d, r_disconnected_event_len
.event_model:
        test    r12, r12
        jz      .event_put
        cmp     qword [r12 + TM_EVENT_LEN], 0
        je      .event_put
        mov     rcx, [r12 + TM_EVENT_PTR]
        mov     r8, [r12 + TM_EVENT_LEN]
.event_put:
        cmp     r8, [rsp + TL_EVENT_W]
        cmova   r8, [rsp + TL_EVENT_W]
        mov     rdi, rbx
        mov     rsi, [rsp + TL_EVENT_X]
        mov     rdx, [rsp + TL_EVENT_Y]
        call    _af_tui_render_put_utf8

        mov     r8d, r_commands_len
        cmp     r8, [rsp + TL_COMMAND_W]
        cmova   r8, [rsp + TL_COMMAND_W]
        mov     rdi, rbx
        mov     rsi, [rsp + TL_COMMAND_X]
        mov     rdx, [rsp + TL_COMMAND_Y]
        lea     rcx, [r_commands]
        call    _af_tui_render_put_ascii
        AF_LEAVE_OK

.too_small:
        mov     rdi, rbx
        xor     esi, esi
        xor     edx, edx
        lea     rcx, [r_small_1]
        mov     r8d, r_small_1_len
        call    _af_tui_render_put_ascii
        cmp     qword [rbx + TC_HEIGHT], 1
        jbe     .small_done
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 1
        lea     rcx, [r_small_2]
        mov     r8d, r_small_2_len
        call    _af_tui_render_put_ascii
.small_done:
        AF_LEAVE_OK

.not_found:
        mov     rax, AF_E_NOTFOUND
        jmp     .return
.invalid:
        mov     rax, AF_E_INVALID
        jmp     .return
.limit:
        mov     rax, AF_E_LIMIT
.return:
        AF_LEAVE

        global af_tui_model_struct_size
af_tui_model_struct_size:
        mov     eax, TM_SIZE
        ret

        global af_tui_row_struct_size
af_tui_row_struct_size:
        mov     eax, TR_SIZE
        ret
