; AsmFlow — seven stable screen and status descriptors.
;
; Descriptor storage is STATIC and immutable.  Returned pointers are BORROWED
; for process lifetime.  Column widths are the deterministic minimums used by
; the pure renderer; lower-priority fields move to detail as width contracts.

        bits 64
        default rel

%include "asmflow.inc"
%include "tui.inc"

        extern af_tui_columns_fit

        section .rodata

title_overview:  db "OVERVIEW"
title_overview_len equ $ - title_overview
title_providers: db "PROVIDERS"
title_providers_len equ $ - title_providers
title_routes:    db "ROUTES"
title_routes_len equ $ - title_routes
title_requests:  db "REQUESTS"
title_requests_len equ $ - title_requests
title_mcp:       db "MCP"
title_mcp_len equ $ - title_mcp
title_logs:      db "LOGS"
title_logs_len equ $ - title_logs
title_settings:  db "SETTINGS"
title_settings_len equ $ - title_settings

col_status:      db "STATUS"
col_status_len equ $ - col_status
col_name:        db "NAME"
col_name_len equ $ - col_name
col_value:       db "VALUE"
col_value_len equ $ - col_value
col_detail:      db "DETAIL"
col_detail_len equ $ - col_detail
col_adapter:     db "ADAPTER"
col_adapter_len equ $ - col_adapter
col_active_max:  db "ACTIVE/MAX"
col_active_max_len equ $ - col_active_max
; The control contract exposes an EWMA, not a percentile.  Never mislabel it
; LATENCY_P95 until a distinct percentile field exists.
col_latency:     db "LATENCY"
col_latency_len equ $ - col_latency
col_circuit:     db "CIRCUIT"
col_circuit_len equ $ - col_circuit
col_last_error:  db "LAST_ERROR"
col_last_error_len equ $ - col_last_error
col_alias:       db "ALIAS"
col_alias_len equ $ - col_alias
col_policy:      db "POLICY"
col_policy_len equ $ - col_policy
col_targets:     db "TARGETS"
col_targets_len equ $ - col_targets
col_eligible:    db "ELIGIBLE"
col_eligible_len equ $ - col_eligible
col_active:      db "ACTIVE"
col_active_len equ $ - col_active
col_fallback:    db "FALLBACK"
col_fallback_len equ $ - col_fallback
col_selected:    db "LAST_SELECTED"
col_selected_len equ $ - col_selected
col_time:        db "TIME"
col_time_len equ $ - col_time
col_id:          db "ID"
col_id_len equ $ - col_id
col_endpoint:    db "ENDPOINT"
col_endpoint_len equ $ - col_endpoint
col_model:       db "MODEL"
col_model_len equ $ - col_model
col_provider:    db "PROVIDER"
col_provider_len equ $ - col_provider
col_state:       db "STATE"
col_state_len equ $ - col_state
col_ttfb:        db "TTFB"
col_ttfb_len equ $ - col_ttfb
col_total:       db "TOTAL"
col_total_len equ $ - col_total
col_transport:   db "TRANSPORT"
col_transport_len equ $ - col_transport
col_era:         db "ERA"
col_era_len equ $ - col_era
col_version:     db "VERSION"
col_version_len equ $ - col_version
col_tools:       db "TOOLS"
col_tools_len equ $ - col_tools
col_resources:   db "RESOURCES"
col_resources_len equ $ - col_resources
col_restarts:    db "RESTARTS"
col_restarts_len equ $ - col_restarts
col_level:       db "LEVEL"
col_level_len equ $ - col_level
col_component:   db "COMPONENT"
col_component_len equ $ - col_component
col_event:       db "EVENT"
col_event_len equ $ - col_event
col_key:         db "KEY"
col_key_len equ $ - col_key

status_ok:       db "[OK]"
status_ok_len equ $ - status_ok
status_warn:     db "[WARN]"
status_warn_len equ $ - status_warn
status_open:     db "[OPEN]"
status_open_len equ $ - status_open
status_fail:     db "[FAIL]"
status_fail_len equ $ - status_fail
status_off:      db "[OFF]"
status_off_len equ $ - status_off
status_run:      db "[RUN]"
status_run_len equ $ - status_run

%macro TUI_COLUMN 7
        dq %1, %2, %3, %4, %5, %6, %7
%endmacro

        section .data.rel.ro progbits align=8

overview_columns:
        TUI_COLUMN 1, 0, 7, 7, AF_TUI_ALIGN_LEFT, col_status, col_status_len
        TUI_COLUMN 2, 0, 18, 28, AF_TUI_ALIGN_LEFT, col_name, col_name_len
        TUI_COLUMN 3, 1, 12, 18, AF_TUI_ALIGN_RIGHT, col_value, col_value_len
        TUI_COLUMN 4, 2, 20, 40, AF_TUI_ALIGN_LEFT, col_detail, col_detail_len
overview_columns_count equ ($ - overview_columns) / TCD_SIZE

providers_columns:
        TUI_COLUMN 1, 0, 7, 7, AF_TUI_ALIGN_LEFT, col_status, col_status_len
        TUI_COLUMN 2, 0, 14, 24, AF_TUI_ALIGN_LEFT, col_name, col_name_len
        TUI_COLUMN 3, 2, 9, 16, AF_TUI_ALIGN_LEFT, col_adapter, col_adapter_len
        TUI_COLUMN 4, 1, 10, 12, AF_TUI_ALIGN_RIGHT, col_active_max, col_active_max_len
        TUI_COLUMN 5, 1, 9, 12, AF_TUI_ALIGN_RIGHT, col_latency, col_latency_len
        TUI_COLUMN 6, 1, 7, 10, AF_TUI_ALIGN_LEFT, col_circuit, col_circuit_len
        TUI_COLUMN 7, 3, 14, 32, AF_TUI_ALIGN_LEFT, col_last_error, col_last_error_len
providers_columns_count equ ($ - providers_columns) / TCD_SIZE

routes_columns:
        TUI_COLUMN 1, 0, 16, 24, AF_TUI_ALIGN_LEFT, col_alias, col_alias_len
        TUI_COLUMN 2, 1, 14, 16, AF_TUI_ALIGN_LEFT, col_policy, col_policy_len
        TUI_COLUMN 3, 2, 8, 10, AF_TUI_ALIGN_RIGHT, col_targets, col_targets_len
        TUI_COLUMN 4, 0, 10, 12, AF_TUI_ALIGN_RIGHT, col_eligible, col_eligible_len
        TUI_COLUMN 5, 2, 8, 10, AF_TUI_ALIGN_RIGHT, col_active, col_active_len
        TUI_COLUMN 6, 2, 10, 12, AF_TUI_ALIGN_LEFT, col_fallback, col_fallback_len
        TUI_COLUMN 7, 3, 16, 24, AF_TUI_ALIGN_LEFT, col_selected, col_selected_len
routes_columns_count equ ($ - routes_columns) / TCD_SIZE

requests_columns:
        TUI_COLUMN 1, 1, 10, 12, AF_TUI_ALIGN_LEFT, col_time, col_time_len
        TUI_COLUMN 2, 0, 18, 26, AF_TUI_ALIGN_LEFT, col_id, col_id_len
        TUI_COLUMN 3, 2, 10, 12, AF_TUI_ALIGN_LEFT, col_endpoint, col_endpoint_len
        TUI_COLUMN 4, 0, 12, 18, AF_TUI_ALIGN_LEFT, col_model, col_model_len
        TUI_COLUMN 5, 1, 14, 20, AF_TUI_ALIGN_LEFT, col_provider, col_provider_len
        TUI_COLUMN 6, 0, 10, 12, AF_TUI_ALIGN_LEFT, col_state, col_state_len
        TUI_COLUMN 7, 1, 8, 10, AF_TUI_ALIGN_RIGHT, col_status, col_status_len
        TUI_COLUMN 8, 2, 8, 10, AF_TUI_ALIGN_RIGHT, col_ttfb, col_ttfb_len
        TUI_COLUMN 9, 2, 8, 10, AF_TUI_ALIGN_RIGHT, col_total, col_total_len
requests_columns_count equ ($ - requests_columns) / TCD_SIZE

mcp_columns:
        TUI_COLUMN 1, 0, 7, 7, AF_TUI_ALIGN_LEFT, col_status, col_status_len
        TUI_COLUMN 2, 0, 16, 24, AF_TUI_ALIGN_LEFT, col_name, col_name_len
        TUI_COLUMN 3, 1, 10, 12, AF_TUI_ALIGN_LEFT, col_transport, col_transport_len
        TUI_COLUMN 4, 1, 12, 14, AF_TUI_ALIGN_LEFT, col_era, col_era_len
        TUI_COLUMN 5, 2, 12, 14, AF_TUI_ALIGN_LEFT, col_version, col_version_len
        TUI_COLUMN 6, 1, 7, 9, AF_TUI_ALIGN_RIGHT, col_tools, col_tools_len
        TUI_COLUMN 7, 2, 10, 12, AF_TUI_ALIGN_RIGHT, col_resources, col_resources_len
        TUI_COLUMN 8, 1, 8, 10, AF_TUI_ALIGN_RIGHT, col_restarts, col_restarts_len
mcp_columns_count equ ($ - mcp_columns) / TCD_SIZE

logs_columns:
        TUI_COLUMN 1, 0, 7, 8, AF_TUI_ALIGN_LEFT, col_level, col_level_len
        TUI_COLUMN 2, 1, 12, 16, AF_TUI_ALIGN_LEFT, col_component, col_component_len
        TUI_COLUMN 3, 0, 24, 40, AF_TUI_ALIGN_LEFT, col_event, col_event_len
        TUI_COLUMN 4, 2, 16, 24, AF_TUI_ALIGN_LEFT, col_id, col_id_len
        TUI_COLUMN 5, 1, 10, 12, AF_TUI_ALIGN_LEFT, col_time, col_time_len
logs_columns_count equ ($ - logs_columns) / TCD_SIZE

settings_columns:
        TUI_COLUMN 1, 0, 22, 28, AF_TUI_ALIGN_LEFT, col_key, col_key_len
        TUI_COLUMN 2, 0, 24, 40, AF_TUI_ALIGN_LEFT, col_value, col_value_len
        TUI_COLUMN 3, 1, 10, 14, AF_TUI_ALIGN_LEFT, col_state, col_state_len
settings_columns_count equ ($ - settings_columns) / TCD_SIZE

screen_descriptors:
        dq AF_TUI_SCREEN_OVERVIEW,  '1', title_overview,  title_overview_len,  overview_columns,  overview_columns_count
        dq AF_TUI_SCREEN_PROVIDERS, '2', title_providers, title_providers_len, providers_columns, providers_columns_count
        dq AF_TUI_SCREEN_ROUTES,    '3', title_routes,    title_routes_len,    routes_columns,    routes_columns_count
        dq AF_TUI_SCREEN_REQUESTS,  '4', title_requests,  title_requests_len,  requests_columns,  requests_columns_count
        dq AF_TUI_SCREEN_MCP,       '5', title_mcp,       title_mcp_len,       mcp_columns,       mcp_columns_count
        dq AF_TUI_SCREEN_LOGS,      '6', title_logs,      title_logs_len,      logs_columns,      logs_columns_count
        dq AF_TUI_SCREEN_SETTINGS,  '7', title_settings,  title_settings_len,  settings_columns,  settings_columns_count

status_pointers:
        dq status_ok, status_warn, status_open, status_fail, status_off, status_run
status_lengths:
        dq status_ok_len, status_warn_len, status_open_len
        dq status_fail_len, status_off_len, status_run_len

        section .text

        global af_tui_screen_descriptors
af_tui_screen_descriptors:
        lea     rax, [screen_descriptors]
        ret

        global af_tui_screen_count
af_tui_screen_count:
        mov     eax, AF_TUI_SCREEN_COUNT
        ret

; af_tui_screen_descriptor(u64 id) -> STATIC descriptor or NULL.
        global af_tui_screen_descriptor
af_tui_screen_descriptor:
        cmp     rdi, AF_TUI_SCREEN_OVERVIEW
        jb      .not_found
        cmp     rdi, AF_TUI_SCREEN_SETTINGS
        ja      .not_found
        dec     rdi
        imul    rdi, TSD_SIZE
        lea     rax, [screen_descriptors]
        add     rax, rdi
        ret
.not_found:
        xor     eax, eax
        ret

; af_tui_status_label(u64 status, u64 *out_len) -> STATIC bytes or NULL.
        global af_tui_status_label
af_tui_status_label:
        test    rsi, rsi
        jz      .status_not_found
        cmp     rdi, AF_TUI_STATUS_COUNT
        jae     .status_not_found
        lea     rax, [status_lengths]
        mov     rcx, [rax + rdi * 8]
        mov     [rsi], rcx
        lea     rax, [status_pointers]
        mov     rax, [rax + rdi * 8]
        ret
.status_not_found:
        xor     eax, eax
        ret

; af_tui_screen_columns_fit(id, available, out_fit) -> af_status.
        global af_tui_screen_columns_fit
af_tui_screen_columns_fit:
        AF_ENTER 0
        mov     rbx, rsi
        mov     r12, rdx
        call    af_tui_screen_descriptor
        test    rax, rax
        jz      .not_found
        mov     rdi, [rax + TSD_COLUMNS]
        mov     rsi, [rax + TSD_COLUMN_COUNT]
        mov     rdx, rbx
        mov     ecx, 1
        mov     r8, r12
        call    af_tui_columns_fit
        AF_LEAVE
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND

        global af_tui_screen_descriptor_size
af_tui_screen_descriptor_size:
        mov     eax, TSD_SIZE
        ret
