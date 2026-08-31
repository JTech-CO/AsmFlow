; AsmFlow — complete, deterministic action-risk catalogue.
;
; Descriptors are STATIC.  Confirmation is derived from risk, but availability
; is explicit: a catalogue entry must not become interactive merely because it
; is below Level 4.  This keeps future daemon methods unreachable until the TUI
; has a complete parameter and confirmation path for them.

        bits 64
        default rel

%include "asmflow.inc"
%include "tui.inc"

        section .rodata

%macro TUI_STRING 2
%1:     db %2
%1 %+ _len equ $ - %1
%endmacro

TUI_STRING a_view, "View"
TUI_STRING a_filter, "Filter"
TUI_STRING a_sort, "Sort"
TUI_STRING a_open, "Open detail"
TUI_STRING a_help, "Help"
TUI_STRING a_quit, "Quit console"
TUI_STRING a_refresh, "Refresh snapshot"
TUI_STRING a_provider_probe, "Probe provider"
TUI_STRING a_mcp_discover, "Discover MCP inventory"
TUI_STRING a_diagnostics, "Export diagnostics"
TUI_STRING a_provider_enable, "Enable provider"
TUI_STRING a_provider_disable, "Disable provider"
TUI_STRING a_mcp_start, "Start MCP server"
TUI_STRING a_mcp_stop, "Stop MCP server"
TUI_STRING a_mcp_restart, "Restart MCP server"
TUI_STRING a_mcp_reset, "Reset MCP crash loop"
TUI_STRING a_config_reload, "Reload configuration"
TUI_STRING a_mcp_tool, "Test MCP tool"
TUI_STRING a_route_mutate, "Mutate route"
TUI_STRING a_nonloopback, "Enable non-loopback listener"
TUI_STRING a_multi_stop, "Stop multiple MCP servers"
TUI_STRING a_db_reset, "Reset database"

TUI_STRING m_provider_probe, "provider.probe"
TUI_STRING m_mcp_discover, "mcp.discover"
TUI_STRING m_diagnostics, "diagnostics.export"
TUI_STRING m_provider_enable, "provider.enable"
TUI_STRING m_provider_disable, "provider.disable"
TUI_STRING m_mcp_start, "mcp.start"
TUI_STRING m_mcp_stop, "mcp.stop"
TUI_STRING m_mcp_restart, "mcp.restart"
TUI_STRING m_mcp_reset, "mcp.reset_crash_loop"
TUI_STRING m_config_reload, "config.reload"
TUI_STRING m_mcp_tool, "mcp.tool_test"

; TUI_ACTION id, risk, available, label, label_len, method, method_len
%macro TUI_ACTION 7
    %assign %%flags 0
    %if %2 >= AF_TUI_RISK_2
        %assign %%flags %%flags | AF_TUI_AF_CONFIRM
    %endif
    %if %3
        %assign %%flags %%flags | AF_TUI_AF_AVAILABLE
    %endif
        dq %1, %2, %%flags, %4, %5, %6, %7
%endmacro

        section .data.rel.ro progbits align=8
action_descriptors:
        TUI_ACTION AF_TUI_ACTION_VIEW, AF_TUI_RISK_0, 1, a_view, a_view_len, 0, 0
        TUI_ACTION AF_TUI_ACTION_FILTER, AF_TUI_RISK_0, 0, a_filter, a_filter_len, 0, 0
        TUI_ACTION AF_TUI_ACTION_SORT, AF_TUI_RISK_0, 0, a_sort, a_sort_len, 0, 0
        TUI_ACTION AF_TUI_ACTION_OPEN, AF_TUI_RISK_0, 0, a_open, a_open_len, 0, 0
        TUI_ACTION AF_TUI_ACTION_HELP, AF_TUI_RISK_0, 1, a_help, a_help_len, 0, 0
        TUI_ACTION AF_TUI_ACTION_QUIT, AF_TUI_RISK_0, 1, a_quit, a_quit_len, 0, 0
        TUI_ACTION AF_TUI_ACTION_REFRESH, AF_TUI_RISK_1, 1, a_refresh, a_refresh_len, 0, 0
        TUI_ACTION AF_TUI_ACTION_PROVIDER_PROBE, AF_TUI_RISK_1, 0, a_provider_probe, a_provider_probe_len, m_provider_probe, m_provider_probe_len
        TUI_ACTION AF_TUI_ACTION_MCP_DISCOVER, AF_TUI_RISK_1, 0, a_mcp_discover, a_mcp_discover_len, m_mcp_discover, m_mcp_discover_len
        TUI_ACTION AF_TUI_ACTION_DIAGNOSTICS_EXPORT, AF_TUI_RISK_1, 0, a_diagnostics, a_diagnostics_len, m_diagnostics, m_diagnostics_len
        TUI_ACTION AF_TUI_ACTION_PROVIDER_ENABLE, AF_TUI_RISK_2, 0, a_provider_enable, a_provider_enable_len, m_provider_enable, m_provider_enable_len
        TUI_ACTION AF_TUI_ACTION_PROVIDER_DISABLE, AF_TUI_RISK_2, 0, a_provider_disable, a_provider_disable_len, m_provider_disable, m_provider_disable_len
        TUI_ACTION AF_TUI_ACTION_MCP_START, AF_TUI_RISK_2, 0, a_mcp_start, a_mcp_start_len, m_mcp_start, m_mcp_start_len
        TUI_ACTION AF_TUI_ACTION_MCP_STOP, AF_TUI_RISK_2, 0, a_mcp_stop, a_mcp_stop_len, m_mcp_stop, m_mcp_stop_len
        TUI_ACTION AF_TUI_ACTION_MCP_RESTART, AF_TUI_RISK_2, 1, a_mcp_restart, a_mcp_restart_len, m_mcp_restart, m_mcp_restart_len
        TUI_ACTION AF_TUI_ACTION_MCP_RESET_CRASH_LOOP, AF_TUI_RISK_2, 0, a_mcp_reset, a_mcp_reset_len, m_mcp_reset, m_mcp_reset_len
        TUI_ACTION AF_TUI_ACTION_CONFIG_RELOAD, AF_TUI_RISK_2, 0, a_config_reload, a_config_reload_len, m_config_reload, m_config_reload_len
        TUI_ACTION AF_TUI_ACTION_MCP_TOOL_TEST, AF_TUI_RISK_3, 0, a_mcp_tool, a_mcp_tool_len, m_mcp_tool, m_mcp_tool_len
        TUI_ACTION AF_TUI_ACTION_ROUTE_MUTATE, AF_TUI_RISK_3, 0, a_route_mutate, a_route_mutate_len, 0, 0
        TUI_ACTION AF_TUI_ACTION_LISTENER_NONLOOPBACK, AF_TUI_RISK_3, 0, a_nonloopback, a_nonloopback_len, 0, 0
        TUI_ACTION AF_TUI_ACTION_MULTI_SERVER_STOP, AF_TUI_RISK_4, 0, a_multi_stop, a_multi_stop_len, 0, 0
        TUI_ACTION AF_TUI_ACTION_DB_RESET, AF_TUI_RISK_4, 0, a_db_reset, a_db_reset_len, 0, 0
action_descriptors_end:

AF_STATIC_ASSERT ((action_descriptors_end - action_descriptors) / TAD_SIZE) = AF_TUI_ACTION_COUNT, "TUI action count drift"

        section .text

        global af_tui_action_descriptors
af_tui_action_descriptors:
        lea     rax, [action_descriptors]
        ret

        global af_tui_action_count
af_tui_action_count:
        mov     eax, AF_TUI_ACTION_COUNT
        ret

; af_tui_action_descriptor(u64 id) -> STATIC descriptor or NULL.
        global af_tui_action_descriptor
af_tui_action_descriptor:
        cmp     rdi, 1
        jb      .not_found
        cmp     rdi, AF_TUI_ACTION_COUNT
        ja      .not_found
        dec     rdi
        imul    rdi, TAD_SIZE
        lea     rax, [action_descriptors]
        add     rax, rdi
        ret
.not_found:
        xor     eax, eax
        ret

; af_tui_action_requires_confirmation(const descriptor *d) -> i64.
        global af_tui_action_requires_confirmation
af_tui_action_requires_confirmation:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        test    qword [rdi + TAD_FLAGS], AF_TUI_AF_CONFIRM
        setnz   al
.done:
        ret

; af_tui_action_available(const descriptor *d) -> i64.
        global af_tui_action_available
af_tui_action_available:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        test    qword [rdi + TAD_FLAGS], AF_TUI_AF_AVAILABLE
        setnz   al
.done:
        ret

; af_tui_action_validate_table() -> af_status.
;
; A runtime/static-gate-friendly proof that table bytes obey the construction
; rule even after future hand edits.
        global af_tui_action_validate_table
af_tui_action_validate_table:
        AF_ENTER 0
        lea     rbx, [action_descriptors]
        xor     r12d, r12d
.scan:
        cmp     r12, AF_TUI_ACTION_COUNT
        jae     .valid
        mov     rax, r12
        imul    rax, TAD_SIZE
        add     rax, rbx
        mov     rcx, [rax + TAD_RISK]
        cmp     rcx, AF_TUI_RISK_4
        ja      .invalid
        cmp     rcx, AF_TUI_RISK_2
        jb      .low_risk
        test    qword [rax + TAD_FLAGS], AF_TUI_AF_CONFIRM
        jz      .invalid
.low_risk:
        cmp     rcx, AF_TUI_RISK_4
        jne     .next
        test    qword [rax + TAD_FLAGS], AF_TUI_AF_AVAILABLE
        jnz     .invalid
.next:
        inc     r12
        jmp     .scan
.valid:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INTERNAL

        global af_tui_action_descriptor_size
af_tui_action_descriptor_size:
        mov     eax, TAD_SIZE
        ret
