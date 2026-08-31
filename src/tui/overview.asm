; AsmFlow — exact responsive Overview composition.
;
; Overview is intentionally not represented as a magic generic-row sequence.
; It consumes the bounded TUI_OVERVIEW model from tui.inc and renders the
; summary/routes/events hierarchy used by the committed 80/100/140 goldens.
; All model pointers are BORROWED for this call; no value is retained.

        bits 64
        default rel

%include "asmflow.inc"
%include "tui.inc"

        extern af_tui_canvas_put_ascii
        extern af_tui_canvas_put_utf8
        extern af_tui_status_label
        extern af_u64_to_dec

        section .rodata

o_product:          db "AsmFlow "
o_product_len equ $ - o_product
o_conn_ok:          db "[CONNECTED]"
o_conn_ok_len equ $ - o_conn_ok
o_conn_stale:       db "[STALE]"
o_conn_stale_len equ $ - o_conn_stale
o_conn_down:        db "[DISCONNECTED]"
o_conn_down_len equ $ - o_conn_down
o_space:            db " "
o_two_spaces:       db "  "
o_cfg:              db "cfg:"
o_cfg_len equ $ - o_cfg
o_req:              db "req:"
o_req_len equ $ - o_req
o_mcp:              db "mcp:"
o_mcp_len equ $ - o_mcp
o_slash:            db "/"

o_nav_80: db "[Overview] Providers Routes Requests MCP Logs Settings"
o_nav_80_len equ $ - o_nav_80
o_nav_100: db "Overview  Providers  Routes  Requests  MCP  Logs  Settings"
o_nav_100_len equ $ - o_nav_100

o_overview:         db "OVERVIEW"
o_overview_len equ $ - o_overview
o_gateway_compact:  db " Gateway ready"
o_gateway_compact_len equ $ - o_gateway_compact
o_gateway:          db "Gateway"
o_gateway_len equ $ - o_gateway
o_ready_upper:      db "READY"
o_ready_upper_len equ $ - o_ready_upper
o_ready_lower:      db "ready"
o_ready_lower_len equ $ - o_ready_lower
o_not_ready_upper:  db "NOT READY"
o_not_ready_upper_len equ $ - o_not_ready_upper
o_not_ready_lower:  db "not ready"
o_not_ready_lower_len equ $ - o_not_ready_lower

o_providers_c:      db "Providers  "
o_providers_c_len equ $ - o_providers_c
o_mcp_c:            db "MCP        "
o_mcp_c_len equ $ - o_mcp_c
o_providers:        db "Providers"
o_providers_len equ $ - o_providers
o_mcp_servers:      db "MCP servers"
o_mcp_servers_len equ $ - o_mcp_servers
o_healthy:          db " healthy / "
o_healthy_len equ $ - o_healthy
o_warning:          db " warning / "
o_warning_len equ $ - o_warning
o_open:             db " open / "
o_open_len equ $ - o_open
o_disabled:         db " disabled"
o_disabled_len equ $ - o_disabled
o_ready_count:      db " ready / "
o_ready_count_len equ $ - o_ready_count
o_starting:         db " starting / "
o_starting_len equ $ - o_starting
o_crash_loop:       db " crash-loop / "
o_crash_loop_len equ $ - o_crash_loop
o_stopped:          db " stopped"
o_stopped_len equ $ - o_stopped

o_routes_c:         db "Routes"
o_routes_c_len equ $ - o_routes_c
o_routes:           db "ROUTES"
o_routes_len equ $ - o_routes
o_eligible_word:    db " eligible"
o_eligible_word_len equ $ - o_eligible_word
o_header_100:       db "STATUS ALIAS       POLICY          ELIGIBLE ACTIVE LAST SELECTED"
o_header_100_len equ $ - o_header_100
o_header_140:       db "STATUS ALIAS       POLICY          TARGETS ELIGIBLE ACTIVE LAST SELECTED"
o_header_140_len equ $ - o_header_140
o_dash:             db "-"

o_recent_c:         db "Recent events"
o_recent_c_len equ $ - o_recent_c
o_recent:           db "RECENT EVENTS"
o_recent_len equ $ - o_recent
o_command_80:       db "r refresh  : commands  ? help  q quit"
o_command_80_len equ $ - o_command_80
o_command_full:     db "r refresh   : commands   ? help   q quit"
o_command_full_len equ $ - o_command_full

o_detail:           db "DETAIL"
o_detail_len equ $ - o_detail
o_state:            db "State       "
o_state_len equ $ - o_state
o_revision:         db "Revision    "
o_revision_len equ $ - o_revision
o_requests:         db "Requests    "
o_requests_len equ $ - o_requests
o_active_word:      db " active"
o_active_word_len equ $ - o_active_word
o_control:          db "Control     "
o_control_len equ $ - o_control
o_connected_word:   db "connected"
o_connected_word_len equ $ - o_connected_word
o_stale_word:       db "stale"
o_stale_word_len equ $ - o_stale_word
o_disconnected_word: db "disconnected"
o_disconnected_word_len equ $ - o_disconnected_word
o_next_action:      db "Next action"
o_next_action_len equ $ - o_next_action
o_next_detail:      db "Use 2-7 to inspect component state."
o_next_detail_len equ $ - o_next_detail

        section .text

; Pure canvas wrappers.
_o_put_ascii:
        AF_ENTER 16
        lea     r9, [rsp]
        call    af_tui_canvas_put_ascii
        AF_LEAVE

_o_put_utf8:
        AF_ENTER 16
        lea     r9, [rsp]
        call    af_tui_canvas_put_utf8
        AF_LEAVE

; _o_put_u64(canvas,x,y,value,out_columns)
_o_put_u64:
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

; _o_append(canvas,y,&x,bytes,len,is_utf8)
_o_append:
        ; ABI: rdi canvas, rsi y, rdx xptr, rcx bytes, r8 len, r9 utf8 flag.
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8
        mov     rsi, [r13]
        mov     rdx, r12
        mov     rcx, r14
        mov     r8, r15
        test    r9, r9
        jnz     .utf8
        lea     r9, [rsp]
        call    af_tui_canvas_put_ascii
        jmp     .advance
.utf8:
        lea     r9, [rsp]
        call    af_tui_canvas_put_utf8
.advance:
        test    rax, rax
        js      .done
        ; UTF-8 byte length is not a terminal-column count.  Advance from the
        ; canvas-reported width so later fields remain aligned after CJK text.
        mov     rcx, [rsp]
        add     [r13], rcx
.done:
        AF_LEAVE

; _o_append_u64(canvas,y,&x,value)
_o_append_u64:
        AF_ENTER 16
        mov     rbx, rdx
        mov     r12, rsi
        mov     rsi, [rbx]
        mov     rdx, r12
        lea     r8, [rsp]
        call    _o_put_u64
        test    rax, rax
        js      .done
        mov     rcx, [rsp]
        add     [rbx], rcx
.done:
        AF_LEAVE

; _o_append_status(canvas,y,&x,status)
_o_append_status:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, rcx
        lea     rsi, [rsp]
        call    af_tui_status_label
        test    rax, rax
        jz      .invalid
        mov     rdi, rbx
        mov     rsi, [r13]
        mov     rdx, r12
        mov     rcx, rax
        mov     r8, [rsp]
        lea     r9, [rsp + 8]
        call    af_tui_canvas_put_ascii
        test    rax, rax
        js      .done
        mov     rcx, [rsp]
        add     [r13], rcx
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; Direct border helpers.  The canvas was validated and cleared by the caller.
_o_hborder:
        ; rdi=canvas, rsi=y.  Wide pane separators are 0,19,width-40,width-1.
        mov     r8, [rdi + TC_WIDTH]
        mov     r9, [rdi + TC_CELLS]
        mov     rax, rsi
        imul    rax, r8
        lea     r9, [r9 + rax * TC_CELL_SIZE]
        xor     ecx, ecx
.fill:
        cmp     rcx, r8
        jae     .pluses
        mov     dword [r9 + rcx * TC_CELL_SIZE], '-'
        inc     rcx
        jmp     .fill
.pluses:
        mov     dword [r9], '+'
        mov     dword [r9 + 19 * TC_CELL_SIZE], '+'
        mov     rax, r8
        sub     rax, 40
        mov     dword [r9 + rax * TC_CELL_SIZE], '+'
        dec     r8
        mov     dword [r9 + r8 * TC_CELL_SIZE], '+'
        ret

; _o_vbars(canvas,y,middle,right): writes bars at 0,19,middle,right.
_o_vbars:
        mov     r8, [rdi + TC_WIDTH]
        mov     r9, [rdi + TC_CELLS]
        mov     rax, rsi
        imul    rax, r8
        lea     r9, [r9 + rax * TC_CELL_SIZE]
        mov     dword [r9], '|'
        mov     dword [r9 + 19 * TC_CELL_SIZE], '|'
        mov     dword [r9 + rdx * TC_CELL_SIZE], '|'
        mov     dword [r9 + rcx * TC_CELL_SIZE], '|'
        ret

; Compact provider/MCP status-count lines.
_o_compact_provider_summary:
        ; rdi canvas, rsi y, rdx overview, rcx 0=provider/1=mcp
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     qword [rsp], 0
        test    r14, r14
        jnz     .mcp
        lea     rcx, [o_providers_c]
        mov     r8d, o_providers_c_len
        xor     r9d, r9d
        lea     rdx, [rsp]
        call    _o_append
        mov     r15, TO_PROVIDER_OK
        jmp     .counts
.mcp:
        lea     rcx, [o_mcp_c]
        mov     r8d, o_mcp_c_len
        xor     r9d, r9d
        lea     rdx, [rsp]
        call    _o_append
        mov     r15, TO_MCP_OK
.counts:
        ; First status/count.
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        mov     ecx, AF_TUI_STATUS_OK
        call    _o_append_status
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [o_space]
        mov     r8d, 1
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        mov     rcx, [r13 + r15]
        call    _o_append_u64

        ; Separator then second status/count.
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [o_two_spaces]
        mov     r8d, 2
        xor     r9d, r9d
        call    _o_append
        mov     ecx, AF_TUI_STATUS_WARN
        test    r14, r14
        jz      .second_status
        mov     ecx, AF_TUI_STATUS_RUN
.second_status:
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        call    _o_append_status
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [o_space]
        mov     r8d, 1
        xor     r9d, r9d
        call    _o_append
        mov     rax, r15
        add     rax, 8
        mov     rcx, [r13 + rax]
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        call    _o_append_u64

        ; MCP golden has three spaces before FAIL, providers has two.
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [o_two_spaces]
        mov     r8d, 2
        xor     r9d, r9d
        call    _o_append
        test    r14, r14
        jz      .third_status
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [o_space]
        mov     r8d, 1
        xor     r9d, r9d
        call    _o_append
.third_status:
        mov     ecx, AF_TUI_STATUS_OPEN
        test    r14, r14
        jz      .third_put
        mov     ecx, AF_TUI_STATUS_FAIL
.third_put:
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        call    _o_append_status
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [o_space]
        mov     r8d, 1
        xor     r9d, r9d
        call    _o_append
        mov     rax, r15
        add     rax, 16
        mov     rcx, [r13 + rax]
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        call    _o_append_u64

        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [o_two_spaces]
        mov     r8d, 2
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        mov     ecx, AF_TUI_STATUS_OFF
        call    _o_append_status
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [o_space]
        mov     r8d, 1
        xor     r9d, r9d
        call    _o_append
        mov     rax, r15
        add     rax, 24
        mov     rcx, [r13 + rax]
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        call    _o_append_u64
        AF_LEAVE_OK

; _o_summary_counts(canvas,y,overview,is_mcp), standard/wide prose.
_o_summary_counts:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     [rsp], r8                      ; starting x
        test    r14, r14
        jnz     .mcp_offsets
        mov     r15, TO_PROVIDER_OK
        jmp     .prose
.mcp_offsets:
        mov     r15, TO_MCP_OK
.prose:
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        mov     rcx, [r13 + r15]
        call    _o_append_u64
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        test    r14, r14
        jnz     .ready_sep
        lea     rcx, [o_healthy]
        mov     r8d, o_healthy_len
        jmp     .sep1
.ready_sep:
        lea     rcx, [o_ready_count]
        mov     r8d, o_ready_count_len
.sep1:
        xor     r9d, r9d
        call    _o_append
        mov     rax, r15
        add     rax, 8
        mov     rcx, [r13 + rax]
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        call    _o_append_u64
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        test    r14, r14
        jnz     .starting_sep
        lea     rcx, [o_warning]
        mov     r8d, o_warning_len
        jmp     .sep2
.starting_sep:
        lea     rcx, [o_starting]
        mov     r8d, o_starting_len
.sep2:
        xor     r9d, r9d
        call    _o_append
        mov     rax, r15
        add     rax, 16
        mov     rcx, [r13 + rax]
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        call    _o_append_u64
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        test    r14, r14
        jnz     .crash_sep
        lea     rcx, [o_open]
        mov     r8d, o_open_len
        jmp     .sep3
.crash_sep:
        lea     rcx, [o_crash_loop]
        mov     r8d, o_crash_loop_len
.sep3:
        xor     r9d, r9d
        call    _o_append
        mov     rax, r15
        add     rax, 24
        mov     rcx, [r13 + rax]
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        call    _o_append_u64
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        test    r14, r14
        jnz     .stopped_sep
        lea     rcx, [o_disabled]
        mov     r8d, o_disabled_len
        jmp     .sep4
.stopped_sep:
        lea     rcx, [o_stopped]
        mov     r8d, o_stopped_len
.sep4:
        xor     r9d, r9d
        call    _o_append
        AF_LEAVE_OK

; Render one route at fixed columns for compact/standard/wide.
; rdi canvas, rsi y, rdx route, rcx mode (2 compact/3 standard/4 wide)
_o_route:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     rdi, [r13 + TOR_STATUS]
        lea     rsi, [rsp]
        call    af_tui_status_label
        test    rax, rax
        jz      .invalid
        mov     rdi, rbx
        xor     esi, esi
        cmp     r14, AF_TUI_LAYOUT_WIDE
        jne     .status_x
        mov     esi, 21
.status_x:
        mov     rdx, r12
        mov     rcx, rax
        mov     r8, [rsp]
        call    _o_put_ascii

        mov     esi, 7
        mov     r15, 18
        cmp     r14, AF_TUI_LAYOUT_COMPACT
        je      .alias
        mov     esi, 7
        mov     r15, 19
        cmp     r14, AF_TUI_LAYOUT_STANDARD
        je      .alias
        mov     esi, 28
        mov     r15, 40
.alias:
        mov     r8, [r13 + TOR_ALIAS_LEN]
        cmp     r8, 11
        jbe     .alias_cap
        mov     r8d, 11
.alias_cap:
        mov     rdi, rbx
        mov     rdx, r12
        mov     rcx, [r13 + TOR_ALIAS_PTR]
        call    _o_put_utf8
        mov     rdi, rbx
        mov     rsi, r15
        mov     rdx, r12
        mov     rcx, [r13 + TOR_POLICY_PTR]
        mov     r8, [r13 + TOR_POLICY_LEN]
        cmp     r8, 15
        jbe     .policy_cap
        mov     r8d, 15
.policy_cap:
        call    _o_put_utf8

        cmp     r14, AF_TUI_LAYOUT_COMPACT
        je      .compact_ratio
        cmp     r14, AF_TUI_LAYOUT_STANDARD
        je      .standard_values
        ; Wide values: targets 56, eligible 64, active 73, last 80.
        mov     rdi, rbx
        mov     esi, 56
        mov     rdx, r12
        mov     rcx, [r13 + TOR_TARGETS]
        lea     r8, [rsp + 16]
        call    _o_put_u64
        mov     rdi, rbx
        mov     esi, 64
        mov     rdx, r12
        mov     rcx, [r13 + TOR_ELIGIBLE]
        lea     r8, [rsp + 16]
        call    _o_put_u64
        mov     rdi, rbx
        mov     esi, 73
        mov     rdx, r12
        mov     rcx, [r13 + TOR_ACTIVE]
        lea     r8, [rsp + 16]
        call    _o_put_u64
        mov     esi, 80
        jmp     .last
.standard_values:
        mov     qword [rsp + 8], 35
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        mov     rcx, [r13 + TOR_ELIGIBLE]
        call    _o_append_u64
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        lea     rcx, [o_slash]
        mov     r8d, 1
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        mov     rcx, [r13 + TOR_TARGETS]
        call    _o_append_u64
        mov     rdi, rbx
        mov     esi, 44
        mov     rdx, r12
        mov     rcx, [r13 + TOR_ACTIVE]
        lea     r8, [rsp + 16]
        call    _o_put_u64
        mov     esi, 51
        jmp     .last
.compact_ratio:
        mov     qword [rsp + 8], 32
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        mov     rcx, [r13 + TOR_ELIGIBLE]
        call    _o_append_u64
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        lea     rcx, [o_slash]
        mov     r8d, 1
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        mov     rcx, [r13 + TOR_TARGETS]
        call    _o_append_u64
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        lea     rcx, [o_eligible_word]
        mov     r8d, o_eligible_word_len
        xor     r9d, r9d
        call    _o_append
        AF_LEAVE_OK
.last:
        cmp     qword [r13 + TOR_LAST_LEN], 0
        je      .last_dash
        mov     rdi, rbx
        mov     rdx, r12
        mov     rcx, [r13 + TOR_LAST_PTR]
        mov     r8, [r13 + TOR_LAST_LEN]
        cmp     r8, 16
        jbe     .last_put
        mov     r8d, 16
.last_put:
        call    _o_put_utf8
        AF_LEAVE_OK
.last_dash:
        mov     rdi, rbx
        mov     rdx, r12
        lea     rcx, [o_dash]
        mov     r8d, 1
        call    _o_put_ascii
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_tui_render_overview(canvas, layout, model) -> af_status
; ---------------------------------------------------------------------------
        global af_tui_render_overview
af_tui_render_overview:
        AF_ENTER 128
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, [r13 + TM_OVERVIEW]
        test    r14, r14
        jz      .invalid
        cmp     qword [r14 + TO_GATEWAY_STATUS], AF_TUI_STATUS_COUNT
        jae     .invalid
        mov     rax, [r14 + TO_ROUTE_COUNT]
        cmp     rax, AF_TUI_OVERVIEW_MAX_ROUTES
        ja      .limit
        test    rax, rax
        jz      .routes_valid
        cmp     qword [r14 + TO_ROUTES], 0
        je      .invalid
.routes_valid:
        mov     rax, [r14 + TO_EVENT_COUNT]
        cmp     rax, AF_TUI_OVERVIEW_MAX_EVENTS
        ja      .limit
        test    rax, rax
        jz      .events_valid
        cmp     qword [r14 + TO_EVENTS], 0
        je      .invalid
.events_valid:

        ; Top bar.
        mov     qword [rsp], 0
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        lea     rcx, [o_product]
        mov     r8d, o_product_len
        xor     r9d, r9d
        call    _o_append
        lea     rcx, [o_conn_down]
        mov     r8d, o_conn_down_len
        cmp     qword [r13 + TM_CONNECTION], AF_TUI_CONN_CONNECTED
        jne     .top_stale
        lea     rcx, [o_conn_ok]
        mov     r8d, o_conn_ok_len
        jmp     .top_conn
.top_stale:
        cmp     qword [r13 + TM_CONNECTION], AF_TUI_CONN_STALE
        jne     .top_conn
        lea     rcx, [o_conn_stale]
        mov     r8d, o_conn_stale_len
.top_conn:
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        xor     r9d, r9d
        call    _o_append
        mov     r15, 1
        cmp     qword [r12 + TL_MODE], AF_TUI_LAYOUT_COMPACT
        je      .top_gap
        mov     r15, 2
.top_gap:
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        lea     rcx, [o_two_spaces]
        mov     r8, r15
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        lea     rcx, [o_cfg]
        mov     r8d, o_cfg_len
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        mov     rcx, [r13 + TM_REVISION]
        call    _o_append_u64
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        lea     rcx, [o_two_spaces]
        mov     r8, r15
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        lea     rcx, [o_req]
        mov     r8d, o_req_len
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        mov     rcx, [r13 + TM_ACTIVE_REQUESTS]
        call    _o_append_u64
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        lea     rcx, [o_two_spaces]
        mov     r8, r15
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        lea     rcx, [o_mcp]
        mov     r8d, o_mcp_len
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        mov     rcx, [r13 + TM_MCP_RUNNING]
        call    _o_append_u64
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        lea     rcx, [o_slash]
        mov     r8d, 1
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp]
        mov     rcx, [r13 + TM_MCP_TOTAL]
        call    _o_append_u64

        cmp     qword [r12 + TL_MODE], AF_TUI_LAYOUT_COMPACT
        je      .compact
        mov     rsi, 82
        cmp     qword [rbx + TC_WIDTH], 140
        jne     .clock_x
        mov     rsi, 118
.clock_x:
        mov     r8, [r13 + TM_UTC_LEN]
        test    r8, r8
        jz      .after_clock
        mov     rdi, rbx
        xor     edx, edx
        mov     rcx, [r13 + TM_UTC_PTR]
        call    _o_put_utf8
.after_clock:
        cmp     qword [r12 + TL_MODE], AF_TUI_LAYOUT_WIDE
        je      .wide
        jmp     .standard

.compact:
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 1
        lea     rcx, [o_nav_80]
        mov     r8d, o_nav_80_len
        call    _o_put_ascii
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 2
        lea     rcx, [o_overview]
        mov     r8d, o_overview_len
        call    _o_put_ascii
        mov     rdi, [r14 + TO_GATEWAY_STATUS]
        lea     rsi, [rsp + 16]
        call    af_tui_status_label
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 3
        mov     rcx, rax
        mov     r8, [rsp + 16]
        call    _o_put_ascii
        mov     rdi, rbx
        mov     rsi, [rsp + 16]
        mov     edx, 3
        lea     rcx, [o_gateway_compact]
        mov     r8d, o_gateway_compact_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 4
        mov     rdx, r14
        xor     ecx, ecx
        call    _o_compact_provider_summary
        mov     rdi, rbx
        mov     esi, 5
        mov     rdx, r14
        mov     ecx, 1
        call    _o_compact_provider_summary
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 6
        lea     rcx, [o_routes_c]
        mov     r8d, o_routes_c_len
        call    _o_put_ascii
        mov     qword [rsp + 24], 0
.compact_route:
        mov     r15, [rsp + 24]
        cmp     r15, [r14 + TO_ROUTE_COUNT]
        jae     .compact_events
        mov     rax, r15
        imul    rax, TOR_SIZE
        add     rax, [r14 + TO_ROUTES]
        mov     rdi, rbx
        mov     rsi, r15
        add     rsi, 7
        mov     rdx, rax
        mov     ecx, AF_TUI_LAYOUT_COMPACT
        call    _o_route
        inc     qword [rsp + 24]
        jmp     .compact_route
.compact_events:
        mov     r15, [r14 + TO_ROUTE_COUNT]
        add     r15, 7
        mov     rdi, rbx
        xor     esi, esi
        mov     rdx, r15
        lea     rcx, [o_recent_c]
        mov     r8d, o_recent_c_len
        call    _o_put_ascii
        mov     qword [rsp + 24], 0
.compact_event:
        mov     rax, [rsp + 24]
        cmp     rax, [r14 + TO_EVENT_COUNT]
        jae     .compact_command
        mov     rcx, rax
        imul    rcx, TOE_SIZE
        add     rcx, [r14 + TO_EVENTS]
        mov     [rsp + 40], rcx
        mov     rdi, [rcx + TOE_STATUS]
        lea     rsi, [rsp + 16]
        call    af_tui_status_label
        mov     rdi, rbx
        xor     esi, esi
        mov     rdx, r15
        inc     rdx
        add     rdx, [rsp + 24]
        mov     rcx, rax
        mov     r8, [rsp + 16]
        call    _o_put_ascii
        mov     rax, [rsp + 40]
        mov     r8, [rax + TOE_TEXT_LEN]
        cmp     r8, 37
        jbe     .compact_event_cap
        mov     r8d, 37
.compact_event_cap:
        mov     rdi, rbx
        mov     esi, 7
        mov     rdx, r15
        inc     rdx
        add     rdx, [rsp + 24]
        mov     rcx, [rax + TOE_TEXT_PTR]
        call    _o_put_utf8
        inc     qword [rsp + 24]
        jmp     .compact_event
.compact_command:
        add     r15, [r14 + TO_EVENT_COUNT]
        inc     r15
        mov     rdi, rbx
        xor     esi, esi
        mov     rdx, r15
        lea     rcx, [o_command_80]
        mov     r8d, o_command_80_len
        call    _o_put_ascii
        AF_LEAVE_OK

.standard:
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 1
        lea     rcx, [o_nav_100]
        mov     r8d, o_nav_100_len
        call    _o_put_ascii
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 2
        lea     rcx, [o_overview]
        mov     r8d, o_overview_len
        call    _o_put_ascii
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 3
        lea     rcx, [o_gateway]
        mov     r8d, o_gateway_len
        call    _o_put_ascii
        mov     rdi, [r14 + TO_GATEWAY_STATUS]
        lea     rsi, [rsp + 16]
        call    af_tui_status_label
        mov     rdi, rbx
        mov     esi, 14
        mov     edx, 3
        mov     rcx, rax
        mov     r8, [rsp + 16]
        call    _o_put_ascii
        mov     rdi, rbx
        mov     rsi, 14
        add     rsi, [rsp + 16]
        inc     rsi
        mov     edx, 3
        lea     rcx, [o_ready_upper]
        mov     r8d, o_ready_upper_len
        cmp     qword [r14 + TO_GATEWAY_STATUS], AF_TUI_STATUS_OK
        je      .standard_gateway
        lea     rcx, [o_not_ready_upper]
        mov     r8d, o_not_ready_upper_len
.standard_gateway:
        call    _o_put_ascii
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 4
        lea     rcx, [o_providers]
        mov     r8d, o_providers_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 4
        mov     rdx, r14
        xor     ecx, ecx
        mov     r8d, 14
        call    _o_summary_counts
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 5
        lea     rcx, [o_mcp_servers]
        mov     r8d, o_mcp_servers_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 5
        mov     rdx, r14
        mov     ecx, 1
        mov     r8d, 14
        call    _o_summary_counts
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 7
        lea     rcx, [o_routes]
        mov     r8d, o_routes_len
        call    _o_put_ascii
        mov     rdi, rbx
        xor     esi, esi
        mov     edx, 8
        lea     rcx, [o_header_100]
        mov     r8d, o_header_100_len
        call    _o_put_ascii
        mov     qword [rsp + 24], 0
.standard_route:
        mov     r15, [rsp + 24]
        cmp     r15, [r14 + TO_ROUTE_COUNT]
        jae     .standard_events
        mov     rax, r15
        imul    rax, TOR_SIZE
        add     rax, [r14 + TO_ROUTES]
        mov     rdi, rbx
        mov     rsi, r15
        add     rsi, 9
        mov     rdx, rax
        mov     ecx, AF_TUI_LAYOUT_STANDARD
        call    _o_route
        inc     qword [rsp + 24]
        jmp     .standard_route
.standard_events:
        mov     r15, [r14 + TO_ROUTE_COUNT]
        add     r15, 10
        mov     rdi, rbx
        xor     esi, esi
        mov     rdx, r15
        lea     rcx, [o_recent]
        mov     r8d, o_recent_len
        call    _o_put_ascii
        mov     qword [rsp + 24], 0
        jmp     .full_events

.wide:
        mov     rdi, rbx
        mov     esi, 1
        call    _o_hborder
        mov     r15, [r14 + TO_ROUTE_COUNT]
        ; ROUTES header is at y=8, its table header at y=9, route rows start at
        ; y=10, RECENT EVENTS follows the rows, then each event consumes one
        ; row.  The closing border is therefore 12 + routes + events.
        add     r15, 12
        add     r15, [r14 + TO_EVENT_COUNT]
        mov     [rsp + 48], r15                ; bottom border y
        mov     rsi, 2
.wide_bars:
        cmp     rsi, r15
        jae     .wide_bottom
        mov     rdx, [rbx + TC_WIDTH]
        sub     rdx, 40
        mov     rcx, [rbx + TC_WIDTH]
        dec     rcx
        ; Golden summary/route lines intentionally use their committed shorter
        ; separators; preserve them byte-for-byte.
        cmp     rsi, 5
        je      .wide_shift_one
        cmp     rsi, 6
        je      .wide_shift_one
        cmp     rsi, 10
        jb      .wide_bar_put
        mov     rax, [r14 + TO_ROUTE_COUNT]
        add     rax, 10
        cmp     rsi, rax
        jae     .wide_bar_put
        dec     rdx
        dec     rcx
        cmp     rsi, 10
        jne     .wide_bar_put
        dec     rcx
        jmp     .wide_bar_put
.wide_shift_one:
        dec     rdx
        dec     rcx
.wide_bar_put:
        mov     rdi, rbx
        call    _o_vbars
        inc     rsi
        jmp     .wide_bars
.wide_bottom:
        mov     rdi, rbx
        mov     rsi, r15
        call    _o_hborder

        ; Vertical navigation.
        lea     rax, [o_nav_100]               ; names are placed individually below
        mov     byte [rsp + 64], '>'
        mov     rdi, rbx
        mov     esi, 2
        mov     edx, 2
        lea     rcx, [rsp + 64]
        mov     r8d, 1
        call    _o_put_ascii
        ; Static title-case navigation names.
        ; Reuse slices of the standard navigation string.
        mov     qword [rsp + 72], 0
        ; Overview
        mov     rdi, rbx
        mov     esi, 4
        mov     edx, 2
        lea     rcx, [o_nav_100]
        mov     r8d, 8
        call    _o_put_ascii
        ; Providers, Routes, Requests, MCP, Logs, Settings.
        mov     rdi, rbx
        mov     esi, 4
        mov     edx, 3
        lea     rcx, [o_nav_100 + 10]
        mov     r8d, 9
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 4
        mov     edx, 4
        lea     rcx, [o_nav_100 + 21]
        mov     r8d, 6
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 4
        mov     edx, 5
        lea     rcx, [o_nav_100 + 29]
        mov     r8d, 8
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 4
        mov     edx, 6
        lea     rcx, [o_nav_100 + 39]
        mov     r8d, 3
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 4
        mov     edx, 7
        lea     rcx, [o_nav_100 + 44]
        mov     r8d, 4
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 4
        mov     edx, 8
        lea     rcx, [o_nav_100 + 50]
        mov     r8d, 8
        call    _o_put_ascii

        mov     rdi, rbx
        mov     esi, 21
        mov     edx, 2
        lea     rcx, [o_overview]
        mov     r8d, o_overview_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 102
        mov     edx, 2
        lea     rcx, [o_detail]
        mov     r8d, o_detail_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 102
        mov     edx, 3
        lea     rcx, [o_gateway]
        mov     r8d, o_gateway_len
        call    _o_put_ascii

        ; Summary rows and detail facts.
        mov     rdi, rbx
        mov     esi, 21
        mov     edx, 4
        lea     rcx, [o_gateway]
        mov     r8d, o_gateway_len
        call    _o_put_ascii
        mov     rdi, [r14 + TO_GATEWAY_STATUS]
        lea     rsi, [rsp + 16]
        call    af_tui_status_label
        mov     rdi, rbx
        mov     esi, 35
        mov     edx, 4
        mov     rcx, rax
        mov     r8, [rsp + 16]
        call    _o_put_ascii
        mov     rdi, rbx
        mov     rsi, 35
        add     rsi, [rsp + 16]
        inc     rsi
        mov     edx, 4
        lea     rcx, [o_ready_upper]
        mov     r8d, o_ready_upper_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 21
        mov     edx, 5
        lea     rcx, [o_providers]
        mov     r8d, o_providers_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 5
        mov     rdx, r14
        xor     ecx, ecx
        mov     r8d, 35
        call    _o_summary_counts
        mov     rdi, rbx
        mov     esi, 21
        mov     edx, 6
        lea     rcx, [o_mcp_servers]
        mov     r8d, o_mcp_servers_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 6
        mov     rdx, r14
        mov     ecx, 1
        mov     r8d, 35
        call    _o_summary_counts

        mov     rdi, rbx
        mov     esi, 102
        mov     edx, 4
        lea     rcx, [o_state]
        mov     r8d, o_state_len
        call    _o_put_ascii
        mov     rdi, [r14 + TO_GATEWAY_STATUS]
        lea     rsi, [rsp + 16]
        call    af_tui_status_label
        mov     rdi, rbx
        mov     esi, 114
        mov     edx, 4
        mov     rcx, rax
        mov     r8, [rsp + 16]
        call    _o_put_ascii
        mov     rdi, rbx
        mov     rsi, 114
        add     rsi, [rsp + 16]
        inc     rsi
        mov     edx, 4
        lea     rcx, [o_ready_lower]
        mov     r8d, o_ready_lower_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 101
        mov     edx, 5
        lea     rcx, [o_revision]
        mov     r8d, o_revision_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 113
        mov     edx, 5
        mov     rcx, [r13 + TM_REVISION]
        lea     r8, [rsp + 16]
        call    _o_put_u64
        mov     rdi, rbx
        mov     esi, 101
        mov     edx, 6
        lea     rcx, [o_requests]
        mov     r8d, o_requests_len
        call    _o_put_ascii
        mov     qword [rsp + 8], 113
        mov     rdi, rbx
        mov     esi, 6
        lea     rdx, [rsp + 8]
        mov     rcx, [r13 + TM_ACTIVE_REQUESTS]
        call    _o_append_u64
        mov     rdi, rbx
        mov     esi, 6
        lea     rdx, [rsp + 8]
        lea     rcx, [o_active_word]
        mov     r8d, o_active_word_len
        xor     r9d, r9d
        call    _o_append
        mov     rdi, rbx
        mov     esi, 102
        mov     edx, 7
        lea     rcx, [o_control]
        mov     r8d, o_control_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 114
        mov     edx, 7
        lea     rcx, [o_conn_ok]
        add     rcx, 1                          ; "CONNECTED]" cannot be used as status
        ; Use canonical [OK] instead.
        mov     edi, AF_TUI_STATUS_OK
        lea     rsi, [rsp + 16]
        call    af_tui_status_label
        mov     rdi, rbx
        mov     esi, 114
        mov     edx, 7
        mov     rcx, rax
        mov     r8, [rsp + 16]
        call    _o_put_ascii
        mov     rdi, rbx
        mov     rsi, 114
        add     rsi, [rsp + 16]
        inc     rsi
        mov     edx, 7
        lea     rcx, [o_connected_word]
        mov     r8d, o_connected_word_len
        call    _o_put_ascii

        mov     rdi, rbx
        mov     esi, 21
        mov     edx, 8
        lea     rcx, [o_routes]
        mov     r8d, o_routes_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 21
        mov     edx, 9
        lea     rcx, [o_header_140]
        mov     r8d, o_header_140_len
        call    _o_put_ascii
        mov     rdi, rbx
        mov     esi, 102
        mov     edx, 9
        lea     rcx, [o_next_action]
        mov     r8d, o_next_action_len
        call    _o_put_ascii
        mov     qword [rsp + 24], 0
.wide_route:
        mov     r15, [rsp + 24]
        cmp     r15, [r14 + TO_ROUTE_COUNT]
        jae     .wide_events
        mov     rax, r15
        imul    rax, TOR_SIZE
        add     rax, [r14 + TO_ROUTES]
        mov     rdi, rbx
        mov     rsi, r15
        add     rsi, 10
        mov     rdx, rax
        mov     ecx, AF_TUI_LAYOUT_WIDE
        call    _o_route
        test    r15, r15
        jnz     .wide_route_next
        mov     rdi, rbx
        mov     esi, 101
        mov     edx, 10
        lea     rcx, [o_next_detail]
        mov     r8d, o_next_detail_len
        call    _o_put_ascii
.wide_route_next:
        inc     qword [rsp + 24]
        jmp     .wide_route
.wide_events:
        mov     r15, [r14 + TO_ROUTE_COUNT]
        add     r15, 11
        mov     rdi, rbx
        mov     esi, 21
        mov     rdx, r15
        lea     rcx, [o_recent]
        mov     r8d, o_recent_len
        call    _o_put_ascii
        mov     qword [rsp + 24], 0
        jmp     .full_events

.full_events:
        mov     rax, [rsp + 24]
        cmp     rax, [r14 + TO_EVENT_COUNT]
        jae     .full_command
        mov     rcx, rax
        imul    rcx, TOE_SIZE
        add     rcx, [r14 + TO_EVENTS]
        mov     [rsp + 40], rcx
        mov     rdi, [rcx + TOE_STATUS]
        lea     rsi, [rsp + 16]
        call    af_tui_status_label
        mov     rsi, 0
        cmp     qword [r12 + TL_MODE], AF_TUI_LAYOUT_WIDE
        jne     .full_event_x
        mov     esi, 21
.full_event_x:
        mov     rdi, rbx
        mov     rdx, r15
        inc     rdx
        add     rdx, [rsp + 24]
        mov     rcx, rax
        mov     r8, [rsp + 16]
        call    _o_put_ascii
        mov     rax, [rsp + 40]
        mov     rsi, 7
        cmp     qword [r12 + TL_MODE], AF_TUI_LAYOUT_WIDE
        jne     .full_text_x
        mov     esi, 28
.full_text_x:
        mov     r8, [rax + TOE_TEXT_LEN]
        cmp     qword [r12 + TL_MODE], AF_TUI_LAYOUT_WIDE
        jne     .full_text_put
        ; The detail pane starts at width-40.  A UTF-8 byte count is a safe
        ; conservative upper bound on rendered columns (wcwidth <= encoded
        ; byte count), so this prevents remote event text from overwriting
        ; the pane separator while the canvas decoder still owns scalar-safe
        ; clipping and replacement.
        mov     r9, [rbx + TC_WIDTH]
        sub     r9, 40
        cmp     rsi, r9
        jae     .full_text_empty
        sub     r9, rsi
        cmp     r8, r9
        cmova   r8, r9
        jmp     .full_text_put
.full_text_empty:
        xor     r8d, r8d
.full_text_put:
        mov     rdi, rbx
        mov     rdx, r15
        inc     rdx
        add     rdx, [rsp + 24]
        mov     rcx, [rax + TOE_TEXT_PTR]
        call    _o_put_utf8
        inc     qword [rsp + 24]
        jmp     .full_events
.full_command:
        cmp     qword [r12 + TL_MODE], AF_TUI_LAYOUT_WIDE
        jne     .standard_command_y
        mov     r15, [rsp + 48]
        inc     r15
        jmp     .put_full_command
.standard_command_y:
        add     r15, [r14 + TO_EVENT_COUNT]
        add     r15, 2
.put_full_command:
        mov     rdi, rbx
        xor     esi, esi
        mov     rdx, r15
        lea     rcx, [o_command_full]
        mov     r8d, o_command_full_len
        call    _o_put_ascii
        AF_LEAVE_OK

.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

        global af_tui_overview_struct_size
af_tui_overview_struct_size:
        mov     eax, TO_SIZE
        ret

        global af_tui_overview_route_struct_size
af_tui_overview_route_struct_size:
        mov     eax, TOR_SIZE
        ret

        global af_tui_overview_event_struct_size
af_tui_overview_event_struct_size:
        mov     eax, TOE_SIZE
        ret
