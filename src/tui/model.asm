; AsmFlow -- bounded control responses to pure TUI presentation models.
;
; The module owns one Jansson document for each response kind.  set_frame
; parses into temporary storage and transfers that reference only after the
; envelope and result shape are valid.  reset decrefs every owned document.
; Presentation models, rows, cells, overview records, and sanitized text live
; in process-local BSS and are BORROWED by the renderer until the next model
; API call.  The TUI runtime is single-threaded; no pointer crosses a callback.

        bits 64
        default rel

%include "asmflow.inc"
%include "control.inc"
%include "json.inc"
%include "tui.inc"
%include "tui_model.inc"

        extern af_mem_zero
        extern af_mem_copy
        extern af_mem_eq
        extern af_u64_to_dec

        extern af_json_parse
        extern af_json_doc_root
        extern af_json_doc_free
        extern af_json_type
        extern af_json_member
        extern af_json_get_string
        extern af_json_get_integer
        extern af_json_get_bool
        extern af_json_get_object
        extern af_json_get_array
        extern af_json_array_at
        extern af_json_array_count

        extern af_tui_status_label

%define TM_SLOT_EMPTY   0
%define TM_SLOT_VALID   1
%define TM_SLOT_INVALID 2

%define TM_SCREEN_ROWS_BYTES  (AF_TUI_MODEL_MAX_ROWS * TR_SIZE)
%define TM_SCREEN_CELLS_BYTES (AF_TUI_MODEL_MAX_ROWS * AF_TUI_ROW_MAX_CELLS * TT_SIZE)
%define TM_ALL_ROWS_BYTES     (AF_TUI_SCREEN_COUNT * TM_SCREEN_ROWS_BYTES)
%define TM_ALL_CELLS_BYTES    (AF_TUI_SCREEN_COUNT * TM_SCREEN_CELLS_BYTES)
%define TM_ALL_TEXT_BYTES     (AF_TUI_SCREEN_COUNT * AF_TUI_TEXT_MAX_BYTES)

%define TM_ITEM_OUTPUT_MAX 4096

        section .rodata

tm_clock: db "00:00:00 UTC"
tm_clock_len equ $ - tm_clock

tm_dash: db "-"
tm_true: db "true"
tm_false: db "false"
tm_esc: db "[ESC]"
tm_ellipsis: db "..."
tm_slash: db "/"
tm_ms: db " ms"

tm_unavailable: db "UNAVAILABLE"
tm_unavailable_len equ $ - tm_unavailable
tm_invalid_title: db "Control response unavailable"
tm_invalid_title_len equ $ - tm_invalid_title
tm_invalid_body: db "The daemon response was invalid. Press r to retry."
tm_invalid_body_len equ $ - tm_invalid_body
tm_invalid_event: db "DISCONNECTED: invalid control response; press r to retry."
tm_invalid_event_len equ $ - tm_invalid_event
tm_provider_detail: db "Use j/k to select providers; r refreshes."
tm_provider_detail_len equ $ - tm_provider_detail
tm_route_detail: db "Use j/k to select routes; r refreshes."
tm_route_detail_len equ $ - tm_route_detail
tm_mcp_detail: db "Use j/k to select servers; : opens commands."
tm_mcp_detail_len equ $ - tm_mcp_detail
tm_settings_detail: db "Secrets are never displayed by the console."
tm_settings_detail_len equ $ - tm_settings_detail
tm_requests_title: db "Request history unavailable"
tm_requests_title_len equ $ - tm_requests_title
tm_requests_event: db "Request history is unavailable in this build."
tm_requests_event_len equ $ - tm_requests_event
tm_logs_title: db "Log streaming unavailable"
tm_logs_title_len equ $ - tm_logs_title
tm_logs_event: db "Log streaming is unavailable in this build."
tm_logs_event_len equ $ - tm_logs_event
tm_control_component: db "control"
tm_control_component_len equ $ - tm_control_component
tm_warn_word: db "WARN"
tm_warn_word_len equ $ - tm_warn_word

tm_event_circuit: db " circuit opened "
tm_event_circuit_len equ $ - tm_event_circuit
tm_event_circuit_suffix: db " times. Open Providers to inspect state."
tm_event_circuit_suffix_len equ $ - tm_event_circuit_suffix
tm_event_crash_prefix: db " is paused in a crash loop. Open MCP to inspect state."
tm_event_crash_prefix_len equ $ - tm_event_crash_prefix

; Envelope keys.
tm_k_ok: db "ok", 0
tm_k_result: db "result", 0
tm_k_error: db "error", 0
tm_k_code: db "code", 0
tm_k_message: db "message", 0

; Shared result keys.
tm_k_id: db "id", 0
tm_k_revision: db "revision", 0
tm_k_ready: db "ready", 0
tm_k_counts: db "counts", 0
tm_k_requests: db "requests", 0
tm_k_display_name: db "display_name", 0
tm_k_enabled: db "enabled", 0
tm_k_operator_disabled: db "operator_disabled", 0
tm_k_health: db "health", 0
tm_k_adapter: db "adapter", 0
tm_k_active_requests: db "active_requests", 0
tm_k_max_concurrency: db "max_concurrency", 0
tm_k_observed_latency_us: db "observed_latency_us", 0
tm_k_circuit_opened_count: db "circuit_opened_count", 0
tm_k_last_error: db "last_error", 0

tm_k_model_alias: db "model_alias", 0
tm_k_policy: db "policy", 0
tm_k_target_count: db "target_count", 0
tm_k_eligible_count: db "eligible_count", 0
tm_k_fallback: db "fallback", 0
tm_k_max_attempts: db "max_attempts", 0
tm_k_last_selected: db "last_selected", 0

tm_k_state: db "state", 0
tm_k_transport: db "transport", 0
tm_k_era: db "era", 0
tm_k_protocol_version: db "protocol_version", 0
tm_k_tool_count: db "tool_count", 0
tm_k_resource_count: db "resource_count", 0
tm_k_restarts: db "restarts", 0

tm_k_config_path: db "config_path", 0
tm_k_listener: db "listener", 0
tm_k_host: db "host", 0
tm_k_port: db "port", 0
tm_k_loopback: db "loopback", 0
tm_k_storage: db "storage", 0
tm_k_schema_version: db "schema_version", 0
tm_k_store_payloads: db "store_payloads", 0
tm_k_auth: db "auth", 0
tm_k_type: db "type", 0
tm_k_secret_present: db "secret_present", 0

; Settings row labels.
tm_s_config_path: db "config.path"
tm_s_config_path_len equ $ - tm_s_config_path
tm_s_listener_host: db "listener.host"
tm_s_listener_host_len equ $ - tm_s_listener_host
tm_s_listener_port: db "listener.port"
tm_s_listener_port_len equ $ - tm_s_listener_port
tm_s_listener_loopback: db "listener.loopback"
tm_s_listener_loopback_len equ $ - tm_s_listener_loopback
tm_s_storage_schema: db "storage.schema_version"
tm_s_storage_schema_len equ $ - tm_s_storage_schema
tm_s_storage_payloads: db "storage.store_payloads"
tm_s_storage_payloads_len equ $ - tm_s_storage_payloads
tm_s_auth_type: db "auth.type"
tm_s_auth_type_len equ $ - tm_s_auth_type
tm_s_auth_present: db "auth.secret_present"
tm_s_auth_present_len equ $ - tm_s_auth_present

; State vocabulary.
tm_v_healthy: db "healthy"
tm_v_healthy_len equ $ - tm_v_healthy
tm_v_degraded: db "degraded"
tm_v_degraded_len equ $ - tm_v_degraded
tm_v_open: db "open"
tm_v_open_len equ $ - tm_v_open
tm_v_half_open: db "half_open"
tm_v_half_open_len equ $ - tm_v_half_open
tm_v_disabled: db "disabled"
tm_v_disabled_len equ $ - tm_v_disabled
tm_v_ready: db "ready"
tm_v_ready_len equ $ - tm_v_ready
tm_v_starting: db "starting"
tm_v_starting_len equ $ - tm_v_starting
tm_v_in_flight: db "in_flight"
tm_v_in_flight_len equ $ - tm_v_in_flight
tm_v_crash_loop: db "crash_loop"
tm_v_crash_loop_len equ $ - tm_v_crash_loop
tm_v_failed: db "failed"
tm_v_failed_len equ $ - tm_v_failed
tm_v_stopped: db "stopped"
tm_v_stopped_len equ $ - tm_v_stopped

tm_c_closed: db "closed"
tm_c_closed_len equ $ - tm_c_closed
tm_c_half_open: db "half-open"
tm_c_half_open_len equ $ - tm_c_half_open

        section .bss
        align 64

tm_docs:           resb AF_TUI_MODEL_KIND_COUNT * AF_JSONDOC_SIZE
tm_slot_states:    resq AF_TUI_MODEL_KIND_COUNT
tm_dirty:          resq AF_TUI_SCREEN_COUNT
tm_models:         resb AF_TUI_SCREEN_COUNT * TM_SIZE
tm_rows:           resb TM_ALL_ROWS_BYTES
tm_cells:          resb TM_ALL_CELLS_BYTES
tm_text:           resb TM_ALL_TEXT_BYTES
tm_text_lens:      resq AF_TUI_SCREEN_COUNT

; Selection is model-owned rather than a pointer into per-build text scratch.
; A refresh can therefore rebuild/reorder every row and still resolve the
; previously focused provider/MCP object by its stable control-plane ID.
tm_selected_ids:     resb AF_TUI_SCREEN_COUNT * AF_CTL_ID_MAX
tm_selected_id_lens: resq AF_TUI_SCREEN_COUNT
tm_selected_indices: resq AF_TUI_SCREEN_COUNT

; Overview has one dedicated screen/cache.
tm_overview:       resb TO_SIZE
tm_overview_routes: resb AF_TUI_OVERVIEW_MAX_ROUTES * TOR_SIZE
tm_overview_events: resb AF_TUI_OVERVIEW_MAX_EVENTS * TOE_SIZE

        section .text

; ---------------------------------------------------------------------------
; Address helpers.  All returned pointers reference process-local STATIC/BSS
; storage; callers borrow them until the next model API call.
; ---------------------------------------------------------------------------
af_tm_doc_ptr:
        imul    rdi, AF_JSONDOC_SIZE
        lea     rax, [tm_docs]
        add     rax, rdi
        ret

af_tm_model_ptr:
        imul    rdi, TM_SIZE
        lea     rax, [tm_models]
        add     rax, rdi
        ret

af_tm_rows_ptr:
        imul    rdi, TM_SCREEN_ROWS_BYTES
        lea     rax, [tm_rows]
        add     rax, rdi
        ret

af_tm_cells_ptr:
        imul    rdi, TM_SCREEN_CELLS_BYTES
        lea     rax, [tm_cells]
        add     rax, rdi
        ret

af_tm_text_ptr:
        imul    rdi, AF_TUI_TEXT_MAX_BYTES
        lea     rax, [tm_text]
        add     rax, rdi
        ret

af_tm_mark_dirty:
        lea     rdx, [tm_dirty]
        xor     ecx, ecx
.loop:
        cmp     rcx, AF_TUI_SCREEN_COUNT
        jae     .done
        mov     qword [rdx + rcx * 8], 1
        inc     rcx
        jmp     .loop
.done:
        ret

; ---------------------------------------------------------------------------
; af_tui_model_reset() -> void
;
; Releases every owned parsed document and invalidates all presentation
; caches.  Idempotent, including before the first set_frame call.
; ---------------------------------------------------------------------------
        global af_tui_model_reset
af_tui_model_reset:
        AF_ENTER 0
        xor     ebx, ebx
.slot:
        cmp     rbx, AF_TUI_MODEL_KIND_COUNT
        jae     .cleared
        mov     rdi, rbx
        call    af_tm_doc_ptr
        mov     rdi, rax
        call    af_json_doc_free
        lea     rax, [tm_slot_states]
        mov     qword [rax + rbx * 8], TM_SLOT_EMPTY
        inc     rbx
        jmp     .slot
.cleared:
        lea     rdi, [tm_text_lens]
        mov     rsi, AF_TUI_SCREEN_COUNT * 8
        call    af_mem_zero
        lea     rdi, [tm_selected_id_lens]
        mov     rsi, AF_TUI_SCREEN_COUNT * 8
        call    af_mem_zero
        lea     rdi, [tm_selected_indices]
        mov     rsi, AF_TUI_SCREEN_COUNT * 8
        call    af_mem_zero
        call    af_tm_mark_dirty
        AF_LEAVE

; Validate the result type for a successful envelope.
; af_tm_kind_type_ok(kind, json_t *result) -> boolean
af_tm_kind_type_ok:
        AF_ENTER 0
        mov     rbx, rdi
        mov     rdi, rsi
        call    af_json_type
        cmp     rbx, AF_TUI_MODEL_KIND_VERSION
        je      .object
        cmp     rbx, AF_TUI_MODEL_KIND_SNAPSHOT
        je      .object
        cmp     rbx, AF_TUI_MODEL_KIND_CONFIG
        je      .object
        cmp     rbx, AF_TUI_MODEL_KIND_PROVIDERS
        je      .array
        cmp     rbx, AF_TUI_MODEL_KIND_ROUTES
        je      .array
        cmp     rbx, AF_TUI_MODEL_KIND_REQUESTS
        je      .array
        cmp     rbx, AF_TUI_MODEL_KIND_MCP
        je      .array
        cmp     rbx, AF_TUI_MODEL_KIND_LOGS
        je      .array
        xor     eax, eax
        AF_LEAVE
.object:
        cmp     rax, AF_JSON_OBJECT
        sete    al
        movzx   eax, al
        AF_LEAVE
.array:
        cmp     rax, AF_JSON_ARRAY
        sete    al
        movzx   eax, al
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_tui_model_set_frame(kind, bytes, len) -> af_status
;
; `bytes` is BORROWED only for this call.  On success the new parsed document
; owns all strings and atomically replaces the old kind document.  A malformed
; frame invalidates that kind so a later build cannot silently present stale
; data as current.
; ---------------------------------------------------------------------------
        global af_tui_model_set_frame
af_tui_model_set_frame:
        AF_ENTER 112
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        cmp     rbx, AF_TUI_MODEL_KIND_VERSION
        jb      .invalid_argument
        cmp     rbx, AF_TUI_MODEL_KIND_CONFIG
        ja      .invalid_argument
        test    r12, r12
        jz      .bad_frame
        test    r13, r13
        jz      .bad_frame
        cmp     r13, AF_TUI_MODEL_FRAME_MAX
        ja      .bad_frame_size

        mov     [rsp + AF_JSONLIM_MAX_BYTES], r13
        mov     qword [rsp + AF_JSONLIM_MAX_DEPTH], AF_TUI_MODEL_JSON_DEPTH
        mov     qword [rsp + AF_JSONLIM_MAX_STRING], AF_TUI_MODEL_FRAME_MAX
        mov     qword [rsp + AF_JSONLIM_MAX_ELEMS], AF_TUI_MODEL_JSON_ELEMENTS
        lea     rdi, [rsp + 32]
        mov     rsi, AF_JSONDOC_SIZE
        call    af_mem_zero
        mov     rdi, r12
        mov     rsi, r13
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        test    rax, rax
        js      .parse_failed
        lea     rdi, [rsp + 32]
        call    af_json_doc_root
        mov     [rsp + 64], rax
        mov     rdi, rax
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .protocol_failed
        mov     rdi, [rsp + 64]
        lea     rsi, [tm_k_ok]
        lea     rdx, [rsp + 72]
        call    af_json_get_bool
        test    rax, rax
        js      .protocol_failed
        cmp     qword [rsp + 72], 0
        je      .error_envelope
        mov     rdi, [rsp + 64]
        lea     rsi, [tm_k_result]
        lea     rdx, [rsp + 80]
        call    af_json_member
        test    rax, rax
        js      .protocol_failed
        mov     rdi, rbx
        mov     rsi, [rsp + 80]
        call    af_tm_kind_type_ok
        test    rax, rax
        jz      .protocol_failed
        jmp     .commit
.error_envelope:
        mov     rdi, [rsp + 64]
        lea     rsi, [tm_k_error]
        lea     rdx, [rsp + 80]
        call    af_json_get_object
        test    rax, rax
        js      .protocol_failed

.commit:
        mov     r14, rbx
        dec     r14
        mov     rdi, r14
        call    af_tm_doc_ptr
        mov     r15, rax
        mov     rdi, r15
        call    af_json_doc_free
        mov     rdi, r15
        lea     rsi, [rsp + 32]
        mov     rdx, AF_JSONDOC_SIZE
        call    af_mem_copy
        ; Ownership moved to the slot: do not decref the temporary copy.
        lea     rax, [tm_slot_states]
        mov     qword [rax + r14 * 8], TM_SLOT_VALID
        ; List selection must be synchronized before runtime actions inspect
        ; selected_id.  The provider refresh path requests providers.get
        ; immediately after set_frame, before the next presentation build.
        cmp     rbx, AF_TUI_MODEL_KIND_PROVIDERS
        je      .sync_providers
        cmp     rbx, AF_TUI_MODEL_KIND_MCP
        je      .sync_mcp
        jmp     .selection_done
.sync_providers:
        cmp     qword [rsp + 72], 0
        je      .clear_provider_selection
        mov     edi, 1
        mov     rsi, [rsp + 80]
        call    af_tm_sync_selection_array
        jmp     .selection_done
.clear_provider_selection:
        lea     rax, [tm_selected_id_lens]
        mov     qword [rax + 8], 0
        jmp     .selection_done
.sync_mcp:
        cmp     qword [rsp + 72], 0
        je      .clear_mcp_selection
        mov     edi, 4
        mov     rsi, [rsp + 80]
        call    af_tm_sync_selection_array
        jmp     .selection_done
.clear_mcp_selection:
        lea     rax, [tm_selected_id_lens]
        mov     qword [rax + 4 * 8], 0
.selection_done:
        call    af_tm_mark_dirty
        AF_LEAVE_OK

.parse_failed:
        mov     r15, rax
        jmp     .invalidate
.protocol_failed:
        mov     r15, AF_E_INVALID
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        jmp     .invalidate_without_temp
.bad_frame_size:
        mov     r15, AF_E_JSON_SIZE
        jmp     .invalidate_without_temp
.bad_frame:
        mov     r15, AF_E_INVALID
.invalidate_without_temp:
.invalidate:
        mov     r14, rbx
        dec     r14
        mov     rdi, r14
        call    af_tm_doc_ptr
        mov     rdi, rax
        call    af_json_doc_free
        lea     rax, [tm_slot_states]
        mov     qword [rax + r14 * 8], TM_SLOT_INVALID
        call    af_tm_mark_dirty
        mov     rax, r15
        AF_LEAVE
.invalid_argument:
        AF_LEAVE_ERR AF_E_INVALID

; af_tm_slot_result(kind, json_t **out) -> af_status
af_tm_slot_result:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        cmp     rbx, 1
        jb      .not_found
        cmp     rbx, AF_TUI_MODEL_KIND_COUNT
        ja      .not_found
        mov     rax, rbx
        dec     rax
        lea     rcx, [tm_slot_states]
        cmp     qword [rcx + rax * 8], TM_SLOT_VALID
        jne     .not_found
        mov     rdi, rax
        call    af_tm_doc_ptr
        mov     rdi, rax
        call    af_json_doc_root
        mov     [rsp], rax
        mov     rdi, rax
        lea     rsi, [tm_k_ok]
        lea     rdx, [rsp + 8]
        call    af_json_get_bool
        test    rax, rax
        js      .done
        cmp     qword [rsp + 8], 0
        je      .state
        mov     rdi, [rsp]
        lea     rsi, [tm_k_result]
        mov     rdx, r12
        call    af_json_member
.done:
        AF_LEAVE
.state:
        AF_LEAVE_ERR AF_E_CTL_STATE
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND

; ---------------------------------------------------------------------------
; Semantic state mapping.  No remote status text is trusted as a terminal
; label; it is mapped onto the six static labels from screens.asm.
; ---------------------------------------------------------------------------
af_tm_provider_status:
        AF_ENTER 48
        mov     rbx, rdi
        mov     rdi, rbx
        lea     rsi, [tm_k_enabled]
        lea     rdx, [rsp + 16]
        call    af_json_get_bool
        test    rax, rax
        js      .operator
        cmp     qword [rsp + 16], 0
        je      .off
.operator:
        mov     rdi, rbx
        lea     rsi, [tm_k_operator_disabled]
        lea     rdx, [rsp + 16]
        call    af_json_get_bool
        test    rax, rax
        js      .health
        cmp     qword [rsp + 16], 0
        jne     .off
.health:
        mov     rdi, rbx
        lea     rsi, [tm_k_health]
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_string
        test    rax, rax
        js      .warn
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_healthy]
        mov     rcx, tm_v_healthy_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .ok
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_degraded]
        mov     rcx, tm_v_degraded_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .warn
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_half_open]
        mov     rcx, tm_v_half_open_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .warn
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_open]
        mov     rcx, tm_v_open_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .open
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_disabled]
        mov     rcx, tm_v_disabled_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .off
.warn:
        mov     eax, AF_TUI_STATUS_WARN
        AF_LEAVE
.ok:
        mov     eax, AF_TUI_STATUS_OK
        AF_LEAVE
.open:
        mov     eax, AF_TUI_STATUS_OPEN
        AF_LEAVE
.off:
        mov     eax, AF_TUI_STATUS_OFF
        AF_LEAVE

af_tm_mcp_status:
        AF_ENTER 32
        lea     rsi, [tm_k_state]
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_string
        test    rax, rax
        js      .fail
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_ready]
        mov     rcx, tm_v_ready_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .ok
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_starting]
        mov     rcx, tm_v_starting_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .run
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_in_flight]
        mov     rcx, tm_v_in_flight_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .run
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_crash_loop]
        mov     rcx, tm_v_crash_loop_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .fail
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_failed]
        mov     rcx, tm_v_failed_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .fail
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_stopped]
        mov     rcx, tm_v_stopped_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .off
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_disabled]
        mov     rcx, tm_v_disabled_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .off
        mov     eax, AF_TUI_STATUS_WARN
        AF_LEAVE
.ok:
        mov     eax, AF_TUI_STATUS_OK
        AF_LEAVE
.run:
        mov     eax, AF_TUI_STATUS_RUN
        AF_LEAVE
.fail:
        mov     eax, AF_TUI_STATUS_FAIL
        AF_LEAVE
.off:
        mov     eax, AF_TUI_STATUS_OFF
        AF_LEAVE

; af_tm_route_values(object,out_target,out_eligible,out_active) -> af_status
af_tm_route_values:
        AF_ENTER 48
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx
        mov     [rsp + 16], rcx
        mov     rdi, rbx
        lea     rsi, [tm_k_target_count]
        lea     rdx, [rsp + 24]
        call    af_json_get_integer
        test    rax, rax
        js      .invalid
        mov     rdi, rbx
        lea     rsi, [tm_k_eligible_count]
        lea     rdx, [rsp + 32]
        call    af_json_get_integer
        test    rax, rax
        js      .invalid
        mov     rdi, rbx
        lea     rsi, [tm_k_active_requests]
        lea     rdx, [rsp + 40]
        call    af_json_get_integer
        test    rax, rax
        js      .invalid
        cmp     qword [rsp + 24], 0
        jl      .invalid
        cmp     qword [rsp + 32], 0
        jl      .invalid
        cmp     qword [rsp + 40], 0
        jl      .invalid
        mov     rax, [rsp]
        mov     rcx, [rsp + 24]
        mov     [rax], rcx
        mov     rax, [rsp + 8]
        mov     rcx, [rsp + 32]
        mov     [rax], rcx
        mov     rax, [rsp + 16]
        mov     rcx, [rsp + 40]
        mov     [rax], rcx
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

af_tm_route_status:
        test    rsi, rsi
        jz      .open
        cmp     rsi, rdi
        jb      .warn
        mov     eax, AF_TUI_STATUS_OK
        ret
.warn:
        mov     eax, AF_TUI_STATUS_WARN
        ret
.open:
        mov     eax, AF_TUI_STATUS_OPEN
        ret

; Fill top-bar metrics from snapshot and MCP documents.
af_tm_fill_common:
        AF_ENTER 80
        mov     rbx, rdi
        lea     rax, [tm_clock]
        mov     [rbx + TM_UTC_PTR], rax
        mov     qword [rbx + TM_UTC_LEN], tm_clock_len
        mov     edi, AF_TUI_MODEL_KIND_SNAPSHOT
        lea     rsi, [rsp]
        call    af_tm_slot_result
        test    rax, rax
        js      .mcp
        mov     r12, [rsp]
        mov     rdi, r12
        lea     rsi, [tm_k_revision]
        lea     rdx, [rsp + 8]
        call    af_json_get_integer
        test    rax, rax
        js      .counts
        cmp     qword [rsp + 8], 0
        jl      .counts
        mov     rax, [rsp + 8]
        mov     [rbx + TM_REVISION], rax
.counts:
        mov     rdi, r12
        lea     rsi, [tm_k_counts]
        lea     rdx, [rsp + 16]
        call    af_json_get_object
        test    rax, rax
        js      .mcp
        mov     rdi, [rsp + 16]
        lea     rsi, [tm_k_requests]
        lea     rdx, [rsp + 24]
        call    af_json_get_integer
        test    rax, rax
        js      .mcp
        cmp     qword [rsp + 24], 0
        jl      .mcp
        mov     rax, [rsp + 24]
        mov     [rbx + TM_ACTIVE_REQUESTS], rax
.mcp:
        mov     edi, AF_TUI_MODEL_KIND_MCP
        lea     rsi, [rsp + 32]
        call    af_tm_slot_result
        test    rax, rax
        js      .done
        mov     r12, [rsp + 32]
        mov     rdi, r12
        call    af_json_array_count
        mov     [rbx + TM_MCP_TOTAL], rax
        mov     r13, rax
        xor     r14d, r14d
        xor     r15d, r15d
.mcp_loop:
        cmp     r14, r13
        jae     .mcp_done
        mov     rdi, r12
        mov     rsi, r14
        lea     rdx, [rsp + 40]
        call    af_json_array_at
        test    rax, rax
        js      .mcp_next
        mov     rdi, [rsp + 40]
        call    af_tm_mcp_status
        cmp     rax, AF_TUI_STATUS_OFF
        je      .mcp_next
        inc     r15
.mcp_next:
        inc     r14
        jmp     .mcp_loop
.mcp_done:
        mov     [rbx + TM_MCP_RUNNING], r15
.done:
        AF_LEAVE_OK

; af_tm_begin_model(screen_index, connection) -> model pointer
af_tm_begin_model:
        AF_ENTER 16
        cmp     rdi, AF_TUI_SCREEN_COUNT
        jae     .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        call    af_tm_model_ptr
        mov     r13, rax
        mov     rdi, r13
        mov     rsi, TM_SIZE
        call    af_mem_zero
        cmp     r12, AF_TUI_CONN_DISCONNECTED
        jbe     .connection_ok
        mov     r12, AF_TUI_CONN_DISCONNECTED
.connection_ok:
        mov     [r13 + TM_CONNECTION], r12
        mov     qword [r13 + TM_SELECTED_INDEX], -1
        mov     rdi, rbx
        call    af_tm_rows_ptr
        mov     [r13 + TM_ROWS], rax
        lea     rax, [tm_text_lens]
        mov     qword [rax + rbx * 8], 0
        mov     rdi, r13
        call    af_tm_fill_common
        mov     rax, r13
        AF_LEAVE
.invalid:
        xor     eax, eax
        AF_LEAVE

af_tm_build_invalid:
        AF_ENTER 0
        mov     rbx, rdi
        mov     rsi, AF_TUI_CONN_DISCONNECTED
        call    af_tm_begin_model
        mov     r12, rax
        lea     rax, [tm_invalid_title]
        mov     [r12 + TM_DETAIL_TITLE_PTR], rax
        mov     qword [r12 + TM_DETAIL_TITLE_LEN], tm_invalid_title_len
        lea     rax, [tm_invalid_body]
        mov     [r12 + TM_DETAIL_BODY_PTR], rax
        mov     qword [r12 + TM_DETAIL_BODY_LEN], tm_invalid_body_len
        lea     rax, [tm_invalid_event]
        mov     [r12 + TM_EVENT_PTR], rax
        mov     qword [r12 + TM_EVENT_LEN], tm_invalid_event_len
        mov     qword [r12 + TM_FLAGS], 1
        mov     rax, r12
        AF_LEAVE

af_tm_publish_rows:
        mov     [rdi + TM_ROW_COUNT], rsi
        test    rsi, rsi
        jz      .empty
        mov     qword [rdi + TM_SELECTED_INDEX], 0
        ret
.empty:
        mov     qword [rdi + TM_SELECTED_INDEX], -1
        ret

; ---------------------------------------------------------------------------
; providers.list -> seven presentation cells and stable IDs.
; ---------------------------------------------------------------------------
af_tm_provider_circuit_cell:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, r13
        call    af_tm_provider_status
        cmp     rax, AF_TUI_STATUS_OFF
        je      .disabled
        mov     rdi, r13
        lea     rsi, [tm_k_health]
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_string
        test    rax, rax
        js      .dash
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_healthy]
        mov     rcx, tm_v_healthy_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .closed
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tm_v_half_open]
        mov     rcx, tm_v_half_open_len
        call    af_tm_span_eq
        test    rax, rax
        jnz     .half_open
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, [rsp]
        mov     rcx, [rsp + 8]
        call    af_tm_tt_sanitize
        AF_LEAVE
.closed:
        mov     rdi, r12
        lea     rsi, [tm_c_closed]
        mov     edx, tm_c_closed_len
        call    af_tm_tt_static
        AF_LEAVE_OK
.half_open:
        mov     rdi, r12
        lea     rsi, [tm_c_half_open]
        mov     edx, tm_c_half_open_len
        call    af_tm_tt_static
        AF_LEAVE_OK
.disabled:
        mov     rdi, r12
        lea     rsi, [tm_v_disabled]
        mov     edx, tm_v_disabled_len
        call    af_tm_tt_static
        AF_LEAVE_OK
.dash:
        mov     rdi, r12
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
        AF_LEAVE_OK

af_tm_build_providers:
        AF_ENTER 96
        mov     rbx, rdi
        mov     edi, 1                 ; zero-based providers screen
        mov     rsi, rbx
        call    af_tm_begin_model
        mov     r12, rax
        mov     edi, AF_TUI_MODEL_KIND_PROVIDERS
        lea     rsi, [rsp]
        call    af_tm_slot_result
        test    rax, rax
        js      .invalid
        mov     r13, [rsp]
        mov     rdi, r13
        call    af_json_array_count
        cmp     rax, AF_TUI_MODEL_MAX_ROWS
        jbe     .count_ok
        mov     rax, AF_TUI_MODEL_MAX_ROWS
.count_ok:
        mov     [rsp + 8], rax
        xor     r14d, r14d
.row:
        cmp     r14, [rsp + 8]
        jae     .publish
        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [rsp + 16]
        call    af_json_array_at
        test    rax, rax
        js      .invalid
        mov     r15, [rsp + 16]
        mov     edi, 1
        mov     rsi, r14
        mov     edx, 7
        call    af_tm_row_init
        test    rax, rax
        jz      .invalid
        mov     [rsp + 24], rax
        mov     [rsp + 32], rdx
        mov     edi, 1
        mov     rsi, rax
        mov     rdx, r15
        call    af_tm_row_id
        test    rax, rax
        js      .invalid

        mov     rdi, r15
        call    af_tm_provider_status
        mov     [rsp + 40], rax
        mov     rdi, [rsp + 32]
        mov     rsi, rax
        call    af_tm_set_status
        test    rax, rax
        js      .invalid
        mov     edi, 1
        mov     rsi, [rsp + 32]
        add     rsi, TT_SIZE
        mov     rdx, r15
        lea     rcx, [tm_k_display_name]
        call    af_tm_cell_string
        test    rax, rax
        js      .invalid
        mov     edi, 1
        mov     rsi, [rsp + 32]
        add     rsi, 2 * TT_SIZE
        mov     rdx, r15
        lea     rcx, [tm_k_adapter]
        call    af_tm_cell_string
        test    rax, rax
        js      .invalid

        mov     rdi, r15
        lea     rsi, [tm_k_active_requests]
        lea     rdx, [rsp + 48]
        call    af_json_get_integer
        test    rax, rax
        js      .pair_dash
        mov     rdi, r15
        lea     rsi, [tm_k_max_concurrency]
        lea     rdx, [rsp + 56]
        call    af_json_get_integer
        test    rax, rax
        js      .pair_dash
        cmp     qword [rsp + 48], 0
        jl      .pair_dash
        cmp     qword [rsp + 56], 0
        jl      .pair_dash
        mov     edi, 1
        mov     rsi, [rsp + 32]
        add     rsi, 3 * TT_SIZE
        mov     rdx, [rsp + 48]
        mov     rcx, [rsp + 56]
        call    af_tm_cell_pair
        test    rax, rax
        js      .invalid
        jmp     .pair_done
.pair_dash:
        mov     rdi, [rsp + 32]
        add     rdi, 3 * TT_SIZE
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
.pair_done:
        mov     rdi, r15
        lea     rsi, [tm_k_observed_latency_us]
        lea     rdx, [rsp + 64]
        call    af_json_get_integer
        xor     edx, edx
        test    rax, rax
        js      .latency
        cmp     qword [rsp + 64], 0
        jle     .latency
        mov     rdx, [rsp + 64]
.latency:
        mov     edi, 1
        mov     rsi, [rsp + 32]
        add     rsi, 4 * TT_SIZE
        call    af_tm_cell_latency
        test    rax, rax
        js      .invalid
        mov     edi, 1
        mov     rsi, [rsp + 32]
        add     rsi, 5 * TT_SIZE
        mov     rdx, r15
        call    af_tm_provider_circuit_cell
        test    rax, rax
        js      .invalid
        mov     edi, 1
        mov     rsi, [rsp + 32]
        add     rsi, 6 * TT_SIZE
        mov     rdx, r15
        lea     rcx, [tm_k_last_error]
        call    af_tm_cell_string
        test    rax, rax
        js      .invalid
        inc     r14
        jmp     .row
.publish:
        mov     rdi, r12
        mov     rsi, [rsp + 8]
        call    af_tm_publish_rows
        cmp     qword [rsp + 8], 0
        je      .done
        mov     rax, [r12 + TM_ROWS]
        mov     rax, [rax + TR_CELLS]
        mov     rcx, [rax + TT_SIZE + TT_PTR]
        mov     [r12 + TM_DETAIL_TITLE_PTR], rcx
        mov     rcx, [rax + TT_SIZE + TT_LEN]
        mov     [r12 + TM_DETAIL_TITLE_LEN], rcx
        lea     rax, [tm_provider_detail]
        mov     [r12 + TM_DETAIL_BODY_PTR], rax
        mov     qword [r12 + TM_DETAIL_BODY_LEN], tm_provider_detail_len
.done:
        mov     rax, r12
        AF_LEAVE
.invalid:
        mov     edi, 1
        call    af_tm_build_invalid
        AF_LEAVE
.state:
        AF_LEAVE_ERR AF_E_CTL_STATE
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND

; af_tm_slot_error(kind, json_t **out) -> af_status
af_tm_slot_error:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        cmp     rbx, 1
        jb      .not_found
        cmp     rbx, AF_TUI_MODEL_KIND_COUNT
        ja      .not_found
        mov     rax, rbx
        dec     rax
        lea     rcx, [tm_slot_states]
        cmp     qword [rcx + rax * 8], TM_SLOT_VALID
        jne     .not_found
        mov     rdi, rax
        call    af_tm_doc_ptr
        mov     rdi, rax
        call    af_json_doc_root
        mov     [rsp], rax
        mov     rdi, rax
        lea     rsi, [tm_k_ok]
        lea     rdx, [rsp + 8]
        call    af_json_get_bool
        test    rax, rax
        js      .done
        cmp     qword [rsp + 8], 0
        jne     .state
        mov     rdi, [rsp]
        lea     rsi, [tm_k_error]
        mov     rdx, r12
        call    af_json_get_object
.done:
        AF_LEAVE
.state:
        AF_LEAVE_ERR AF_E_CTL_STATE
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND

; af_tm_span_eq(ptr,len,static,len) -> boolean
af_tm_span_eq:
        AF_ENTER 0
        cmp     rsi, rcx
        jne     .no
        mov     rsi, rdx
        mov     rdx, rcx
        call    af_mem_eq
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; af_tm_tt_static(TUI_TEXT *out, ptr, len) -> void
af_tm_tt_static:
        mov     [rdi + TT_PTR], rsi
        mov     [rdi + TT_LEN], rdx
        ret

; af_tm_tt_sanitize(screen_index, TUI_TEXT *out, bytes, len) -> af_status
;
; ESC becomes [ESC], C0/C1 controls become visible escapes, and UTF-8 scalar
; byte sequences are copied whole.  Each item is capped to 4096 output bytes;
; truncation is explicit with "..." and never splits a UTF-8 sequence.
af_tm_tt_sanitize:
        AF_ENTER 48
        cmp     rdi, AF_TUI_SCREEN_COUNT
        jae     .invalid
        test    rsi, rsi
        jz      .invalid
        test    rcx, rcx
        jz      .source_ok
        test    rdx, rdx
        jz      .invalid
.source_ok:
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     rdi, rbx
        call    af_tm_text_ptr
        mov     [rsp + 24], rax               ; screen base
        lea     rdx, [tm_text_lens]
        mov     rax, [rdx + rbx * 8]
        mov     [rsp + 16], rax               ; start offset
        cmp     rax, AF_TUI_TEXT_MAX_BYTES
        ja      .limit
        mov     qword [rsp], 0                ; source offset
        mov     qword [rsp + 8], 0            ; output bytes
.loop:
        mov     rax, [rsp]
        cmp     rax, r14
        jae     .finish
        cmp     qword [rsp + 8], TM_ITEM_OUTPUT_MAX - 6
        jae     .truncate
        movzx   eax, byte [r13 + rax]
        cmp     al, 0x1b
        je      .esc
        cmp     al, 9
        je      .tab
        cmp     al, 10
        je      .newline
        cmp     al, 13
        je      .return
        cmp     al, 0x20
        jb      .hex
        cmp     al, 0x7f
        je      .hex
        cmp     al, 0x80
        jb      .one

        ; UTF-8 C1 controls U+0080..U+009F are terminal-significant even
        ; though encoded validly.  Make them visible as \\xNN.
        cmp     al, 0xc2
        jne     .utf8
        mov     rcx, [rsp]
        inc     rcx
        cmp     rcx, r14
        jae     .utf8
        movzx   ecx, byte [r13 + rcx]
        cmp     cl, 0x80
        jb      .utf8
        cmp     cl, 0x9f
        ja      .utf8
        mov     eax, ecx
        add     qword [rsp], 2
        jmp     .hex_value

.utf8:
        mov     ecx, 2
        cmp     al, 0xe0
        jb      .utf8_len_ready
        mov     ecx, 3
        cmp     al, 0xf0
        jb      .utf8_len_ready
        mov     ecx, 4
.utf8_len_ready:
        mov     rax, [rsp]
        add     rax, rcx
        cmp     rax, r14
        ja      .hex_current
        mov     rdx, [rsp + 16]
        add     rdx, [rsp + 8]
        add     rdx, rcx
        cmp     rdx, AF_TUI_TEXT_MAX_BYTES
        ja      .truncate
        mov     rdx, [rsp + 24]
        add     rdx, [rsp + 16]
        add     rdx, [rsp + 8]
        xor     eax, eax
.utf8_copy:
        cmp     rax, rcx
        jae     .utf8_copied
        mov     rsi, [rsp]
        add     rsi, rax
        mov     dil, [r13 + rsi]
        mov     [rdx + rax], dil
        inc     rax
        jmp     .utf8_copy
.utf8_copied:
        add     [rsp], rcx
        add     [rsp + 8], rcx
        jmp     .loop

.one:
        mov     rcx, [rsp + 16]
        add     rcx, [rsp + 8]
        cmp     rcx, AF_TUI_TEXT_MAX_BYTES
        jae     .truncate
        mov     rdx, [rsp + 24]
        add     rdx, rcx
        mov     [rdx], al
        inc     qword [rsp]
        inc     qword [rsp + 8]
        jmp     .loop
.esc:
        lea     rsi, [tm_esc]
        mov     ecx, 5
        inc     qword [rsp]
        jmp     .literal
.tab:
        mov     word [rsp + 32], 0x745c       ; "\\t"
        lea     rsi, [rsp + 32]
        mov     ecx, 2
        inc     qword [rsp]
        jmp     .literal
.newline:
        mov     word [rsp + 32], 0x6e5c       ; "\\n"
        lea     rsi, [rsp + 32]
        mov     ecx, 2
        inc     qword [rsp]
        jmp     .literal
.return:
        mov     word [rsp + 32], 0x725c       ; "\\r"
        lea     rsi, [rsp + 32]
        mov     ecx, 2
        inc     qword [rsp]
        jmp     .literal
.hex_current:
        mov     rax, [rsp]
        movzx   eax, byte [r13 + rax]
        inc     qword [rsp]
        jmp     .hex_value
.hex:
        inc     qword [rsp]
.hex_value:
        mov     byte [rsp + 32], 0x5c
        mov     byte [rsp + 33], 'x'
        mov     ecx, eax
        shr     ecx, 4
        and     ecx, 0x0f
        cmp     ecx, 10
        jb      .hex_hi_digit
        add     ecx, 'a' - 10
        jmp     .hex_hi_store
.hex_hi_digit:
        add     ecx, '0'
.hex_hi_store:
        mov     [rsp + 34], cl
        and     eax, 0x0f
        cmp     eax, 10
        jb      .hex_lo_digit
        add     eax, 'a' - 10
        jmp     .hex_lo_store
.hex_lo_digit:
        add     eax, '0'
.hex_lo_store:
        mov     [rsp + 35], al
        lea     rsi, [rsp + 32]
        mov     ecx, 4
.literal:
        mov     rax, [rsp + 16]
        add     rax, [rsp + 8]
        add     rax, rcx
        cmp     rax, AF_TUI_TEXT_MAX_BYTES
        ja      .truncate
        mov     rdx, [rsp + 24]
        add     rdx, [rsp + 16]
        add     rdx, [rsp + 8]
        xor     eax, eax
.literal_copy:
        cmp     rax, rcx
        jae     .literal_done
        mov     dil, [rsi + rax]
        mov     [rdx + rax], dil
        inc     rax
        jmp     .literal_copy
.literal_done:
        add     [rsp + 8], rcx
        jmp     .loop

.truncate:
        mov     rax, [rsp + 16]
        add     rax, [rsp + 8]
        add     rax, 3
        cmp     rax, AF_TUI_TEXT_MAX_BYTES
        ja      .finish
        mov     rdx, [rsp + 24]
        add     rdx, [rsp + 16]
        add     rdx, [rsp + 8]
        mov     byte [rdx], '.'
        mov     byte [rdx + 1], '.'
        mov     byte [rdx + 2], '.'
        add     qword [rsp + 8], 3
.finish:
        mov     rax, [rsp + 24]
        add     rax, [rsp + 16]
        mov     [r12 + TT_PTR], rax
        mov     rax, [rsp + 8]
        mov     [r12 + TT_LEN], rax
        add     rax, [rsp + 16]
        lea     rdx, [tm_text_lens]
        mov     [rdx + rbx * 8], rax
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

; Append safe static bytes to the most recently allocated TUI_TEXT.
; af_tm_tt_append_raw(screen_index, text, bytes, len) -> af_status
af_tm_tt_append_raw:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        cmp     rbx, AF_TUI_SCREEN_COUNT
        jae     .invalid
        test    r12, r12
        jz      .invalid
        test    r14, r14
        jz      .ok
        test    r13, r13
        jz      .invalid
        mov     rdi, rbx
        call    af_tm_text_ptr
        mov     r15, rax
        lea     rdx, [tm_text_lens]
        mov     rax, [rdx + rbx * 8]
        mov     [rsp], rax
        mov     rcx, [r12 + TT_PTR]
        add     rcx, [r12 + TT_LEN]
        mov     rsi, r15
        add     rsi, rax
        cmp     rcx, rsi
        jne     .invalid
        add     rax, r14
        jc      .limit
        cmp     rax, AF_TUI_TEXT_MAX_BYTES
        ja      .limit
        mov     rdi, r15
        add     rdi, [rsp]
        mov     rsi, r13
        mov     rdx, r14
        call    af_mem_copy
        add     [r12 + TT_LEN], r14
        mov     rax, [rsp]
        add     rax, r14
        lea     rdx, [tm_text_lens]
        mov     [rdx + rbx * 8], rax
.ok:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

; af_tm_tt_append_u64(screen_index, text, value) -> af_status
af_tm_tt_append_u64:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rdx
        lea     rsi, [rsp]
        mov     edx, 20
        lea     rcx, [rsp + 24]
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        mov     rcx, [rsp + 24]
        call    af_tm_tt_append_raw
.done:
        AF_LEAVE

; af_tm_row_init(screen_index,row_index,cell_count) -> row in rax, cells in rdx
af_tm_row_init:
        AF_ENTER 32
        cmp     rdi, AF_TUI_SCREEN_COUNT
        jae     .invalid
        cmp     rsi, AF_TUI_MODEL_MAX_ROWS
        jae     .invalid
        cmp     rdx, AF_TUI_ROW_MAX_CELLS
        ja      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rax, rbx
        imul    rax, AF_TUI_MODEL_MAX_ROWS
        add     rax, r12
        mov     [rsp], rax
        imul    rax, TR_SIZE
        lea     r14, [tm_rows]
        add     r14, rax
        mov     rax, [rsp]
        imul    rax, AF_TUI_ROW_MAX_CELLS * TT_SIZE
        lea     r15, [tm_cells]
        add     r15, rax
        mov     rdi, r14
        mov     rsi, TR_SIZE
        call    af_mem_zero
        test    r13, r13
        jz      .publish
        mov     rdi, r15
        mov     rsi, r13
        imul    rsi, TT_SIZE
        call    af_mem_zero
.publish:
        mov     [r14 + TR_CELLS], r15
        mov     [r14 + TR_CELL_COUNT], r13
        mov     rax, r14
        mov     rdx, r15
        AF_LEAVE
.invalid:
        xor     eax, eax
        xor     edx, edx
        AF_LEAVE

; Copy and validate a stable id into the row's ID span.  Invalid IDs are left
; empty rather than retained for a future mutation request.
; af_tm_row_id(screen_index,row,json_object) -> af_status
af_tm_row_id:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, r13
        lea     rsi, [tm_k_id]
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_string
        test    rax, rax
        js      .empty
        mov     rcx, [rsp + 8]
        test    rcx, rcx
        jz      .empty
        cmp     rcx, AF_CTL_ID_MAX
        ja      .empty
        xor     eax, eax
.check:
        cmp     rax, rcx
        jae     .copy
        mov     rdx, [rsp]
        movzx   edx, byte [rdx + rax]
        cmp     dl, 'a'
        jb      .upper
        cmp     dl, 'z'
        jbe     .next
.upper:
        cmp     dl, 'A'
        jb      .digit
        cmp     dl, 'Z'
        jbe     .next
.digit:
        cmp     dl, '0'
        jb      .punct
        cmp     dl, '9'
        jbe     .next
.punct:
        cmp     dl, '-'
        je      .next
        cmp     dl, '_'
        je      .next
        cmp     dl, '.'
        jne     .empty
.next:
        inc     rax
        jmp     .check
.copy:
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, [rsp]
        mov     rcx, [rsp + 8]
        call    af_tm_tt_sanitize
        AF_LEAVE
.empty:
        mov     qword [r12 + TR_ID_PTR], 0
        mov     qword [r12 + TR_ID_LEN], 0
        AF_LEAVE_OK

; af_tm_set_status(TUI_TEXT *cell, status_enum) -> af_status
af_tm_set_status:
        AF_ENTER 16
        mov     rbx, rdi
        mov     rdi, rsi
        lea     rsi, [rsp]
        call    af_tui_status_label
        test    rax, rax
        jz      .invalid
        mov     [rbx + TT_PTR], rax
        mov     rax, [rsp]
        mov     [rbx + TT_LEN], rax
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_tm_cell_string(screen,cell,object,key) -> af_status; missing => '-'.
af_tm_cell_string:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_string
        test    rax, rax
        js      .dash
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, [rsp]
        mov     rcx, [rsp + 8]
        call    af_tm_tt_sanitize
        AF_LEAVE
.dash:
        mov     rdi, r12
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
        AF_LEAVE_OK

; af_tm_cell_u64(screen,cell,value) -> af_status
af_tm_cell_u64:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rdx
        lea     rsi, [rsp]
        mov     edx, 20
        lea     rcx, [rsp + 24]
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        mov     rcx, [rsp + 24]
        call    af_tm_tt_sanitize
.done:
        AF_LEAVE

; af_tm_cell_int_member(screen,cell,object,key) -> af_status; missing => '-'.
af_tm_cell_int_member:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rdx
        mov     rsi, rcx
        lea     rdx, [rsp]
        call    af_json_get_integer
        test    rax, rax
        js      .dash
        cmp     qword [rsp], 0
        jl      .dash
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, [rsp]
        call    af_tm_cell_u64
        AF_LEAVE
.dash:
        mov     rdi, r12
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
        AF_LEAVE_OK

; af_tm_cell_bool_member(screen,cell,object,key) -> af_status; missing => '-'.
af_tm_cell_bool_member:
        AF_ENTER 16
        mov     r12, rsi
        mov     rdi, rdx
        mov     rsi, rcx
        lea     rdx, [rsp]
        call    af_json_get_bool
        test    rax, rax
        js      .dash
        lea     rsi, [tm_false]
        mov     edx, 5
        cmp     qword [rsp], 0
        je      .set
        lea     rsi, [tm_true]
        mov     edx, 4
.set:
        mov     rdi, r12
        call    af_tm_tt_static
        AF_LEAVE_OK
.dash:
        mov     rdi, r12
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
        AF_LEAVE_OK

; Pair and latency formatters use only bounded stack text, then transfer it to
; the screen scratch so every numeric cell has model-owned ASCII.
af_tm_cell_pair:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     rdi, r13
        lea     rsi, [rsp]
        mov     edx, 20
        lea     rcx, [rsp + 48]
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     rax, [rsp + 48]
        mov     byte [rsp + rax], '/'
        inc     rax
        mov     [rsp + 56], rax
        mov     rdi, r14
        lea     rsi, [rsp + rax]
        mov     rdx, 47
        sub     rdx, rax
        lea     rcx, [rsp + 48]
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     rax, [rsp + 56]
        add     rax, [rsp + 48]
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        mov     rcx, rax
        call    af_tm_tt_sanitize
.done:
        AF_LEAVE

af_tm_cell_latency:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi
        test    rdx, rdx
        jz      .dash
        mov     rax, rdx
        xor     edx, edx
        mov     ecx, 1000
        div     rcx
        mov     r13, rdx
        mov     rdi, rax
        lea     rsi, [rsp]
        mov     edx, 20
        lea     rcx, [rsp + 48]
        call    af_u64_to_dec
        test    rax, rax
        js      .done
        mov     r14, [rsp + 48]
        test    r13, r13
        jz      .unit
        mov     byte [rsp + r14], '.'
        inc     r14
        mov     rax, r13
        xor     edx, edx
        mov     ecx, 100
        div     rcx
        add     al, '0'
        mov     [rsp + r14], al
        mov     rax, rdx
        xor     edx, edx
        mov     ecx, 10
        div     rcx
        add     al, '0'
        mov     [rsp + r14 + 1], al
        add     dl, '0'
        mov     [rsp + r14 + 2], dl
        add     r14, 3
.trim:
        cmp     byte [rsp + r14 - 1], '0'
        jne     .unit
        dec     r14
        jmp     .trim
.unit:
        mov     byte [rsp + r14], ' '
        mov     byte [rsp + r14 + 1], 'm'
        mov     byte [rsp + r14 + 2], 's'
        add     r14, 3
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        mov     rcx, r14
        call    af_tm_tt_sanitize
        AF_LEAVE
.dash:
        mov     rdi, r12
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; routes.list -> seven presentation cells and stable IDs.
; ---------------------------------------------------------------------------
af_tm_build_routes:
        AF_ENTER 112
        mov     rbx, rdi
        mov     edi, 2                 ; zero-based routes screen
        mov     rsi, rbx
        call    af_tm_begin_model
        mov     r12, rax
        mov     edi, AF_TUI_MODEL_KIND_ROUTES
        lea     rsi, [rsp]
        call    af_tm_slot_result
        test    rax, rax
        js      .invalid
        mov     r13, [rsp]
        mov     rdi, r13
        call    af_json_array_count
        cmp     rax, AF_TUI_MODEL_MAX_ROWS
        jbe     .count_ok
        mov     rax, AF_TUI_MODEL_MAX_ROWS
.count_ok:
        mov     [rsp + 8], rax
        xor     r14d, r14d
.row:
        cmp     r14, [rsp + 8]
        jae     .publish
        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [rsp + 16]
        call    af_json_array_at
        test    rax, rax
        js      .invalid
        mov     r15, [rsp + 16]
        mov     edi, 2
        mov     rsi, r14
        mov     edx, 7
        call    af_tm_row_init
        test    rax, rax
        jz      .invalid
        mov     [rsp + 24], rax
        mov     [rsp + 32], rdx
        mov     edi, 2
        mov     rsi, rax
        mov     rdx, r15
        call    af_tm_row_id
        test    rax, rax
        js      .invalid

        mov     edi, 2
        mov     rsi, [rsp + 32]
        mov     rdx, r15
        lea     rcx, [tm_k_model_alias]
        call    af_tm_cell_string
        test    rax, rax
        js      .invalid
        mov     edi, 2
        mov     rsi, [rsp + 32]
        add     rsi, TT_SIZE
        mov     rdx, r15
        lea     rcx, [tm_k_policy]
        call    af_tm_cell_string
        test    rax, rax
        js      .invalid

        mov     rdi, r15
        lea     rsi, [rsp + 48]
        lea     rdx, [rsp + 56]
        lea     rcx, [rsp + 64]
        call    af_tm_route_values
        test    rax, rax
        js      .values_dash
        mov     edi, 2
        mov     rsi, [rsp + 32]
        add     rsi, 2 * TT_SIZE
        mov     rdx, [rsp + 48]
        call    af_tm_cell_u64
        test    rax, rax
        js      .invalid
        mov     edi, 2
        mov     rsi, [rsp + 32]
        add     rsi, 3 * TT_SIZE
        mov     rdx, [rsp + 56]
        call    af_tm_cell_u64
        test    rax, rax
        js      .invalid
        mov     edi, 2
        mov     rsi, [rsp + 32]
        add     rsi, 4 * TT_SIZE
        mov     rdx, [rsp + 64]
        call    af_tm_cell_u64
        test    rax, rax
        js      .invalid
        jmp     .values_done
.values_dash:
        mov     rdi, [rsp + 32]
        add     rdi, 2 * TT_SIZE
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
        mov     rdi, [rsp + 32]
        add     rdi, 3 * TT_SIZE
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
        mov     rdi, [rsp + 32]
        add     rdi, 4 * TT_SIZE
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
.values_done:
        mov     rdi, r15
        lea     rsi, [tm_k_fallback]
        lea     rdx, [rsp + 72]
        call    af_json_get_object
        test    rax, rax
        js      .fallback_dash
        mov     edi, 2
        mov     rsi, [rsp + 32]
        add     rsi, 5 * TT_SIZE
        mov     rdx, [rsp + 72]
        lea     rcx, [tm_k_max_attempts]
        call    af_tm_cell_int_member
        test    rax, rax
        js      .invalid
        jmp     .fallback_done
.fallback_dash:
        mov     rdi, [rsp + 32]
        add     rdi, 5 * TT_SIZE
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
.fallback_done:
        mov     edi, 2
        mov     rsi, [rsp + 32]
        add     rsi, 6 * TT_SIZE
        mov     rdx, r15
        lea     rcx, [tm_k_last_selected]
        call    af_tm_cell_string
        test    rax, rax
        js      .invalid
        inc     r14
        jmp     .row
.publish:
        mov     rdi, r12
        mov     rsi, [rsp + 8]
        call    af_tm_publish_rows
        cmp     qword [rsp + 8], 0
        je      .done
        mov     rax, [r12 + TM_ROWS]
        mov     rax, [rax + TR_CELLS]
        mov     rcx, [rax + TT_PTR]
        mov     [r12 + TM_DETAIL_TITLE_PTR], rcx
        mov     rcx, [rax + TT_LEN]
        mov     [r12 + TM_DETAIL_TITLE_LEN], rcx
        lea     rax, [tm_route_detail]
        mov     [r12 + TM_DETAIL_BODY_PTR], rax
        mov     qword [r12 + TM_DETAIL_BODY_LEN], tm_route_detail_len
.done:
        mov     rax, r12
        AF_LEAVE
.invalid:
        mov     edi, 2
        call    af_tm_build_invalid
        AF_LEAVE

; ---------------------------------------------------------------------------
; mcp.list -> status/name/transport/era/version/counts/restarts.
; ---------------------------------------------------------------------------
af_tm_build_mcp:
        AF_ENTER 80
        mov     rbx, rdi
        mov     edi, 4                 ; zero-based MCP screen
        mov     rsi, rbx
        call    af_tm_begin_model
        mov     r12, rax
        mov     edi, AF_TUI_MODEL_KIND_MCP
        lea     rsi, [rsp]
        call    af_tm_slot_result
        test    rax, rax
        js      .invalid
        mov     r13, [rsp]
        mov     rdi, r13
        call    af_json_array_count
        cmp     rax, AF_TUI_MODEL_MAX_ROWS
        jbe     .count_ok
        mov     rax, AF_TUI_MODEL_MAX_ROWS
.count_ok:
        mov     [rsp + 8], rax
        xor     r14d, r14d
.row:
        cmp     r14, [rsp + 8]
        jae     .publish
        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [rsp + 16]
        call    af_json_array_at
        test    rax, rax
        js      .invalid
        mov     r15, [rsp + 16]
        mov     edi, 4
        mov     rsi, r14
        mov     edx, 8
        call    af_tm_row_init
        test    rax, rax
        jz      .invalid
        mov     [rsp + 24], rax
        mov     [rsp + 32], rdx
        mov     edi, 4
        mov     rsi, rax
        mov     rdx, r15
        call    af_tm_row_id
        test    rax, rax
        js      .invalid
        mov     rdi, r15
        call    af_tm_mcp_status
        mov     rdi, [rsp + 32]
        mov     rsi, rax
        call    af_tm_set_status
        test    rax, rax
        js      .invalid

%macro TM_MCP_STRING 2
        mov     edi, 4
        mov     rsi, [rsp + 32]
        add     rsi, %1 * TT_SIZE
        mov     rdx, r15
        lea     rcx, [%2]
        call    af_tm_cell_string
        test    rax, rax
        js      .invalid
%endmacro
        TM_MCP_STRING 1, tm_k_display_name
        TM_MCP_STRING 2, tm_k_transport
        TM_MCP_STRING 3, tm_k_era
        TM_MCP_STRING 4, tm_k_protocol_version
%unmacro TM_MCP_STRING 2
%macro TM_MCP_INT 2
        mov     edi, 4
        mov     rsi, [rsp + 32]
        add     rsi, %1 * TT_SIZE
        mov     rdx, r15
        lea     rcx, [%2]
        call    af_tm_cell_int_member
        test    rax, rax
        js      .invalid
%endmacro
        TM_MCP_INT 5, tm_k_tool_count
        TM_MCP_INT 6, tm_k_resource_count
        TM_MCP_INT 7, tm_k_restarts
%unmacro TM_MCP_INT 2
        inc     r14
        jmp     .row
.publish:
        mov     rdi, r12
        mov     rsi, [rsp + 8]
        call    af_tm_publish_rows
        cmp     qword [rsp + 8], 0
        je      .done
        mov     rax, [r12 + TM_ROWS]
        mov     rax, [rax + TR_CELLS]
        mov     rcx, [rax + TT_SIZE + TT_PTR]
        mov     [r12 + TM_DETAIL_TITLE_PTR], rcx
        mov     rcx, [rax + TT_SIZE + TT_LEN]
        mov     [r12 + TM_DETAIL_TITLE_LEN], rcx
        lea     rax, [tm_mcp_detail]
        mov     [r12 + TM_DETAIL_BODY_PTR], rax
        mov     qword [r12 + TM_DETAIL_BODY_LEN], tm_mcp_detail_len
.done:
        mov     rax, r12
        AF_LEAVE
.invalid:
        mov     edi, 4
        call    af_tm_build_invalid
        AF_LEAVE

; ---------------------------------------------------------------------------
; requests.list/logs.tail are intentionally unsupported in the daemon build
; represented by the M10 fixtures.  Preserve the daemon's bounded code and
; message instead of hiding the limitation behind an empty list.
; ---------------------------------------------------------------------------
af_tm_build_requests:
        AF_ENTER 96
        mov     rbx, rdi
        mov     edi, 3
        mov     rsi, rbx
        call    af_tm_begin_model
        mov     r12, rax
        mov     edi, AF_TUI_MODEL_KIND_REQUESTS
        lea     rsi, [rsp]
        call    af_tm_slot_error
        test    rax, rax
        js      .invalid
        mov     r13, [rsp]
        mov     edi, 3
        xor     esi, esi
        mov     edx, 9
        call    af_tm_row_init
        test    rax, rax
        jz      .invalid
        mov     [rsp + 8], rax
        mov     [rsp + 16], rdx
        mov     r14, rdx
        mov     r15d, 9
.dash_cells:
        mov     rdi, r14
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
        add     r14, TT_SIZE
        dec     r15
        jnz     .dash_cells
        mov     rdi, [rsp + 16]
        add     rdi, TT_SIZE
        lea     rsi, [tm_unavailable]
        mov     edx, tm_unavailable_len
        call    af_tm_tt_static
        mov     rdi, [rsp + 16]
        add     rdi, 5 * TT_SIZE
        lea     rsi, [tm_unavailable]
        mov     edx, tm_unavailable_len
        call    af_tm_tt_static

        mov     rdi, r13
        lea     rsi, [tm_k_code]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_string
        test    rax, rax
        js      .invalid
        mov     edi, 3
        mov     rsi, [rsp + 16]
        add     rsi, 3 * TT_SIZE        ; mandatory MODEL column
        mov     rdx, [rsp + 24]
        mov     rcx, [rsp + 32]
        call    af_tm_tt_sanitize
        test    rax, rax
        js      .invalid

        mov     rdi, r13
        lea     rsi, [tm_k_message]
        lea     rdx, [rsp + 40]
        lea     rcx, [rsp + 48]
        call    af_json_get_string
        test    rax, rax
        js      .invalid
        mov     edi, 3
        lea     rsi, [rsp + 56]
        mov     rdx, [rsp + 40]
        mov     rcx, [rsp + 48]
        call    af_tm_tt_sanitize
        test    rax, rax
        js      .invalid
        lea     rax, [tm_requests_title]
        mov     [r12 + TM_DETAIL_TITLE_PTR], rax
        mov     qword [r12 + TM_DETAIL_TITLE_LEN], tm_requests_title_len
        mov     rax, [rsp + 56 + TT_PTR]
        mov     [r12 + TM_DETAIL_BODY_PTR], rax
        mov     rax, [rsp + 56 + TT_LEN]
        mov     [r12 + TM_DETAIL_BODY_LEN], rax
        ; The table column is intentionally narrow, but the full-width event
        ; line must preserve the exact daemon error code for operators and
        ; machine-readable golden anchors.
        mov     rax, [rsp + 16]
        add     rax, 3 * TT_SIZE
        mov     rcx, [rax + TT_PTR]
        mov     [r12 + TM_EVENT_PTR], rcx
        mov     rcx, [rax + TT_LEN]
        mov     [r12 + TM_EVENT_LEN], rcx
        mov     rdi, r12
        mov     esi, 1
        call    af_tm_publish_rows
        mov     rax, r12
        AF_LEAVE
.invalid:
        mov     edi, 3
        call    af_tm_build_invalid
        AF_LEAVE

af_tm_build_logs:
        AF_ENTER 96
        mov     rbx, rdi
        mov     edi, 5
        mov     rsi, rbx
        call    af_tm_begin_model
        mov     r12, rax
        mov     edi, AF_TUI_MODEL_KIND_LOGS
        lea     rsi, [rsp]
        call    af_tm_slot_error
        test    rax, rax
        js      .invalid
        mov     r13, [rsp]
        mov     edi, 5
        xor     esi, esi
        mov     edx, 5
        call    af_tm_row_init
        test    rax, rax
        jz      .invalid
        mov     [rsp + 8], rax
        mov     [rsp + 16], rdx
        mov     r14, rdx
        mov     r15d, 5
.dash_cells:
        mov     rdi, r14
        lea     rsi, [tm_dash]
        mov     edx, 1
        call    af_tm_tt_static
        add     r14, TT_SIZE
        dec     r15
        jnz     .dash_cells
        mov     rdi, [rsp + 16]
        lea     rsi, [tm_warn_word]
        mov     edx, tm_warn_word_len
        call    af_tm_tt_static
        mov     rdi, [rsp + 16]
        add     rdi, 2 * TT_SIZE
        lea     rsi, [tm_unavailable]
        mov     edx, tm_unavailable_len
        call    af_tm_tt_static

        mov     rdi, r13
        lea     rsi, [tm_k_code]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_string
        test    rax, rax
        js      .invalid
        mov     edi, 5
        mov     rsi, [rsp + 16]
        add     rsi, TT_SIZE            ; visible priority-1 COMPONENT
        mov     rdx, [rsp + 24]
        mov     rcx, [rsp + 32]
        call    af_tm_tt_sanitize
        test    rax, rax
        js      .invalid

        mov     rdi, r13
        lea     rsi, [tm_k_message]
        lea     rdx, [rsp + 40]
        lea     rcx, [rsp + 48]
        call    af_json_get_string
        test    rax, rax
        js      .invalid
        mov     edi, 5
        lea     rsi, [rsp + 56]
        mov     rdx, [rsp + 40]
        mov     rcx, [rsp + 48]
        call    af_tm_tt_sanitize
        test    rax, rax
        js      .invalid
        lea     rax, [tm_logs_title]
        mov     [r12 + TM_DETAIL_TITLE_PTR], rax
        mov     qword [r12 + TM_DETAIL_TITLE_LEN], tm_logs_title_len
        mov     rax, [rsp + 56 + TT_PTR]
        mov     [r12 + TM_DETAIL_BODY_PTR], rax
        mov     rax, [rsp + 56 + TT_LEN]
        mov     [r12 + TM_DETAIL_BODY_LEN], rax
        ; Keep the exact bounded error code visible outside the collapsed
        ; COMPONENT column; the detail body still carries the daemon message.
        mov     rax, [rsp + 16]
        add     rax, TT_SIZE
        mov     rcx, [rax + TT_PTR]
        mov     [r12 + TM_EVENT_PTR], rcx
        mov     rcx, [rax + TT_LEN]
        mov     [r12 + TM_EVENT_LEN], rcx
        mov     rdi, r12
        mov     esi, 1
        call    af_tm_publish_rows
        mov     rax, r12
        AF_LEAVE
.invalid:
        mov     edi, 5
        call    af_tm_build_invalid
        AF_LEAVE

; Settings rows always use the same {key,value,state} shape.
; af_tm_setting_init(row_index,key,key_len) -> row in rax, cells in rdx
af_tm_setting_init:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     edi, 6
        mov     rsi, rbx
        mov     edx, 3
        call    af_tm_row_init
        test    rax, rax
        jz      .done
        mov     [rsp], rax
        mov     [rsp + 8], rdx
        mov     rdi, rdx
        mov     rsi, r12
        mov     rdx, r13
        call    af_tm_tt_static
        mov     rdi, [rsp + 8]
        add     rdi, 2 * TT_SIZE
        mov     esi, AF_TUI_STATUS_OK
        call    af_tm_set_status
        test    rax, rax
        js      .failed
        mov     rax, [rsp]
        mov     rdx, [rsp + 8]
.done:
        AF_LEAVE
.failed:
        xor     eax, eax
        xor     edx, edx
        AF_LEAVE

af_tm_build_settings:
        AF_ENTER 112
        mov     rbx, rdi
        mov     edi, 6
        mov     rsi, rbx
        call    af_tm_begin_model
        mov     r12, rax
        mov     edi, AF_TUI_MODEL_KIND_CONFIG
        lea     rsi, [rsp]
        call    af_tm_slot_result
        test    rax, rax
        js      .invalid
        mov     r13, [rsp]

        xor     edi, edi
        lea     rsi, [tm_s_config_path]
        mov     edx, tm_s_config_path_len
        call    af_tm_setting_init
        test    rax, rax
        jz      .invalid
        mov     [rsp + 8], rdx
        mov     edi, 6
        lea     rsi, [rdx + TT_SIZE]
        mov     rdx, r13
        lea     rcx, [tm_k_config_path]
        call    af_tm_cell_string
        test    rax, rax
        js      .invalid

        mov     rdi, r13
        lea     rsi, [tm_k_listener]
        lea     rdx, [rsp + 16]
        call    af_json_get_object
        test    rax, rax
        jns     .listener_ready
        mov     [rsp + 16], r13
.listener_ready:
        mov     edi, 1
        lea     rsi, [tm_s_listener_host]
        mov     edx, tm_s_listener_host_len
        call    af_tm_setting_init
        mov     [rsp + 24], rdx
        mov     edi, 6
        lea     rsi, [rdx + TT_SIZE]
        mov     rdx, [rsp + 16]
        lea     rcx, [tm_k_host]
        call    af_tm_cell_string
        test    rax, rax
        js      .invalid
        mov     edi, 2
        lea     rsi, [tm_s_listener_port]
        mov     edx, tm_s_listener_port_len
        call    af_tm_setting_init
        mov     [rsp + 24], rdx
        mov     edi, 6
        lea     rsi, [rdx + TT_SIZE]
        mov     rdx, [rsp + 16]
        lea     rcx, [tm_k_port]
        call    af_tm_cell_int_member
        test    rax, rax
        js      .invalid
        mov     edi, 3
        lea     rsi, [tm_s_listener_loopback]
        mov     edx, tm_s_listener_loopback_len
        call    af_tm_setting_init
        mov     [rsp + 24], rdx
        mov     edi, 6
        lea     rsi, [rdx + TT_SIZE]
        mov     rdx, [rsp + 16]
        lea     rcx, [tm_k_loopback]
        call    af_tm_cell_bool_member
        test    rax, rax
        js      .invalid

        mov     rdi, r13
        lea     rsi, [tm_k_storage]
        lea     rdx, [rsp + 32]
        call    af_json_get_object
        test    rax, rax
        jns     .storage_ready
        mov     [rsp + 32], r13
.storage_ready:
        mov     edi, 4
        lea     rsi, [tm_s_storage_schema]
        mov     edx, tm_s_storage_schema_len
        call    af_tm_setting_init
        mov     [rsp + 40], rdx
        mov     edi, 6
        lea     rsi, [rdx + TT_SIZE]
        mov     rdx, [rsp + 32]
        lea     rcx, [tm_k_schema_version]
        call    af_tm_cell_int_member
        test    rax, rax
        js      .invalid
        mov     edi, 5
        lea     rsi, [tm_s_storage_payloads]
        mov     edx, tm_s_storage_payloads_len
        call    af_tm_setting_init
        mov     [rsp + 40], rdx
        mov     edi, 6
        lea     rsi, [rdx + TT_SIZE]
        mov     rdx, [rsp + 32]
        lea     rcx, [tm_k_store_payloads]
        call    af_tm_cell_bool_member
        test    rax, rax
        js      .invalid

        mov     rdi, r13
        lea     rsi, [tm_k_auth]
        lea     rdx, [rsp + 48]
        call    af_json_get_object
        test    rax, rax
        jns     .auth_ready
        mov     [rsp + 48], r13
.auth_ready:
        mov     edi, 6
        lea     rsi, [tm_s_auth_type]
        mov     edx, tm_s_auth_type_len
        call    af_tm_setting_init
        mov     [rsp + 56], rdx
        mov     edi, 6
        lea     rsi, [rdx + TT_SIZE]
        mov     rdx, [rsp + 48]
        lea     rcx, [tm_k_type]
        call    af_tm_cell_string
        test    rax, rax
        js      .invalid
        mov     edi, 7
        lea     rsi, [tm_s_auth_present]
        mov     edx, tm_s_auth_present_len
        call    af_tm_setting_init
        mov     [rsp + 56], rdx
        mov     edi, 6
        lea     rsi, [rdx + TT_SIZE]
        mov     rdx, [rsp + 48]
        lea     rcx, [tm_k_secret_present]
        call    af_tm_cell_bool_member
        test    rax, rax
        js      .invalid

        mov     rdi, r12
        mov     esi, 8
        call    af_tm_publish_rows
        lea     rax, [tm_settings_detail]
        mov     [r12 + TM_DETAIL_BODY_PTR], rax
        mov     qword [r12 + TM_DETAIL_BODY_LEN], tm_settings_detail_len
        mov     rax, r12
        AF_LEAVE
.invalid:
        mov     edi, 6
        call    af_tm_build_invalid
        AF_LEAVE

; ---------------------------------------------------------------------------
; Overview projection.  Dedicated route/event structures deliberately copy
; only presentation fields; no json_t pointer is exposed to the renderer.
; ---------------------------------------------------------------------------
; af_tm_overview_route_rows(routes_array) -> count
af_tm_overview_route_rows:
        AF_ENTER 80
        mov     rbx, rdi
        mov     rdi, rbx
        call    af_json_array_count
        cmp     rax, AF_TUI_OVERVIEW_MAX_ROUTES
        jbe     .count_ok
        mov     rax, AF_TUI_OVERVIEW_MAX_ROUTES
.count_ok:
        mov     [rsp], rax
        xor     r12d, r12d
.row:
        cmp     r12, [rsp]
        jae     .done
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        call    af_json_array_at
        test    rax, rax
        js      .failed
        mov     r13, [rsp + 8]
        mov     rax, r12
        imul    rax, TOR_SIZE
        lea     r14, [tm_overview_routes]
        add     r14, rax
        mov     rdi, r13
        lea     rsi, [rsp + 16]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_tm_route_values
        test    rax, rax
        js      .failed
        mov     rdi, [rsp + 16]
        mov     rsi, [rsp + 24]
        call    af_tm_route_status
        mov     [r14 + TOR_STATUS], rax
        mov     rax, [rsp + 16]
        mov     [r14 + TOR_TARGETS], rax
        mov     rax, [rsp + 24]
        mov     [r14 + TOR_ELIGIBLE], rax
        mov     rax, [rsp + 32]
        mov     [r14 + TOR_ACTIVE], rax
        xor     edi, edi
        lea     rsi, [r14 + TOR_ALIAS_PTR]
        mov     rdx, r13
        lea     rcx, [tm_k_model_alias]
        call    af_tm_cell_string
        test    rax, rax
        js      .failed
        xor     edi, edi
        lea     rsi, [r14 + TOR_POLICY_PTR]
        mov     rdx, r13
        lea     rcx, [tm_k_policy]
        call    af_tm_cell_string
        test    rax, rax
        js      .failed
        xor     edi, edi
        lea     rsi, [r14 + TOR_LAST_PTR]
        mov     rdx, r13
        lea     rcx, [tm_k_last_selected]
        call    af_tm_cell_string
        test    rax, rax
        js      .failed
        inc     r12
        jmp     .row
.done:
        mov     rax, [rsp]
        AF_LEAVE
.failed:
        xor     eax, eax
        AF_LEAVE

; af_tm_overview_events(providers_array,mcp_array) -> count
af_tm_overview_events:
        AF_ENTER 96
        mov     rbx, rdi
        mov     r12, rsi
        xor     r13d, r13d
        mov     rdi, rbx
        call    af_json_array_count
        mov     [rsp], rax
        xor     r14d, r14d
.provider:
        cmp     r14, [rsp]
        jae     .mcp_begin
        cmp     r13, AF_TUI_OVERVIEW_MAX_EVENTS
        jae     .done
        mov     rdi, rbx
        mov     rsi, r14
        lea     rdx, [rsp + 8]
        call    af_json_array_at
        test    rax, rax
        js      .provider_next
        mov     r15, [rsp + 8]
        mov     rdi, r15
        call    af_tm_provider_status
        cmp     rax, AF_TUI_STATUS_OPEN
        jne     .provider_next
        mov     rdi, r15
        lea     rsi, [tm_k_circuit_opened_count]
        lea     rdx, [rsp + 16]
        call    af_json_get_integer
        test    rax, rax
        js      .provider_next
        cmp     qword [rsp + 16], 0
        jle     .provider_next
        mov     rdi, r15
        lea     rsi, [tm_k_display_name]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_string
        test    rax, rax
        js      .provider_next
        mov     rax, r13
        imul    rax, TOE_SIZE
        lea     r15, [tm_overview_events]
        add     r15, rax
        mov     qword [r15 + TOE_STATUS], AF_TUI_STATUS_OPEN
        xor     edi, edi
        lea     rsi, [r15 + TOE_TEXT_PTR]
        mov     rdx, [rsp + 24]
        mov     rcx, [rsp + 32]
        call    af_tm_tt_sanitize
        test    rax, rax
        js      .provider_next
        xor     edi, edi
        lea     rsi, [r15 + TOE_TEXT_PTR]
        lea     rdx, [tm_event_circuit]
        mov     ecx, tm_event_circuit_len
        call    af_tm_tt_append_raw
        test    rax, rax
        js      .provider_next
        xor     edi, edi
        lea     rsi, [r15 + TOE_TEXT_PTR]
        mov     rdx, [rsp + 16]
        call    af_tm_tt_append_u64
        test    rax, rax
        js      .provider_next
        xor     edi, edi
        lea     rsi, [r15 + TOE_TEXT_PTR]
        lea     rdx, [tm_event_circuit_suffix]
        mov     ecx, tm_event_circuit_suffix_len
        call    af_tm_tt_append_raw
        test    rax, rax
        js      .provider_next
        inc     r13
        jmp     .mcp_begin             ; one highest-severity provider event
.provider_next:
        inc     r14
        jmp     .provider

.mcp_begin:
        mov     rdi, r12
        call    af_json_array_count
        mov     [rsp + 40], rax
        xor     r14d, r14d
.mcp:
        cmp     r14, [rsp + 40]
        jae     .done
        cmp     r13, AF_TUI_OVERVIEW_MAX_EVENTS
        jae     .done
        mov     rdi, r12
        mov     rsi, r14
        lea     rdx, [rsp + 48]
        call    af_json_array_at
        test    rax, rax
        js      .mcp_next
        mov     r15, [rsp + 48]
        mov     rdi, r15
        lea     rsi, [tm_k_state]
        lea     rdx, [rsp + 56]
        lea     rcx, [rsp + 64]
        call    af_json_get_string
        test    rax, rax
        js      .mcp_next
        mov     rdi, [rsp + 56]
        mov     rsi, [rsp + 64]
        lea     rdx, [tm_v_crash_loop]
        mov     rcx, tm_v_crash_loop_len
        call    af_tm_span_eq
        test    rax, rax
        jz      .mcp_next
        mov     rdi, r15
        lea     rsi, [tm_k_display_name]
        lea     rdx, [rsp + 72]
        lea     rcx, [rsp + 80]
        call    af_json_get_string
        test    rax, rax
        js      .mcp_next
        mov     rax, r13
        imul    rax, TOE_SIZE
        lea     r15, [tm_overview_events]
        add     r15, rax
        mov     qword [r15 + TOE_STATUS], AF_TUI_STATUS_FAIL
        xor     edi, edi
        lea     rsi, [r15 + TOE_TEXT_PTR]
        mov     rdx, [rsp + 72]
        mov     rcx, [rsp + 80]
        call    af_tm_tt_sanitize
        test    rax, rax
        js      .mcp_next
        xor     edi, edi
        lea     rsi, [r15 + TOE_TEXT_PTR]
        lea     rdx, [tm_event_crash_prefix]
        mov     ecx, tm_event_crash_prefix_len
        call    af_tm_tt_append_raw
        test    rax, rax
        js      .mcp_next
        inc     r13
        jmp     .done                  ; one crash-loop event is actionable
.mcp_next:
        inc     r14
        jmp     .mcp
.done:
        mov     rax, r13
        AF_LEAVE

af_tm_build_overview:
        AF_ENTER 128
        mov     rbx, rdi
        xor     edi, edi
        mov     rsi, rbx
        call    af_tm_begin_model
        mov     r12, rax
        lea     rdi, [tm_overview]
        mov     rsi, TO_SIZE
        call    af_mem_zero
        lea     rdi, [tm_overview_routes]
        mov     rsi, AF_TUI_OVERVIEW_MAX_ROUTES * TOR_SIZE
        call    af_mem_zero
        lea     rdi, [tm_overview_events]
        mov     rsi, AF_TUI_OVERVIEW_MAX_EVENTS * TOE_SIZE
        call    af_mem_zero
        lea     rax, [tm_overview]
        mov     [r12 + TM_OVERVIEW], rax
        lea     rcx, [tm_overview_routes]
        mov     [rax + TO_ROUTES], rcx
        lea     rcx, [tm_overview_events]
        mov     [rax + TO_EVENTS], rcx

        mov     edi, AF_TUI_MODEL_KIND_SNAPSHOT
        lea     rsi, [rsp]
        call    af_tm_slot_result
        test    rax, rax
        js      .invalid
        mov     r13, [rsp]
        mov     rdi, r13
        lea     rsi, [tm_k_ready]
        lea     rdx, [rsp + 8]
        call    af_json_get_bool
        test    rax, rax
        js      .invalid
        lea     r15, [tm_overview]
        mov     qword [r15 + TO_GATEWAY_STATUS], AF_TUI_STATUS_FAIL
        cmp     qword [rsp + 8], 0
        je      .providers
        mov     qword [r15 + TO_GATEWAY_STATUS], AF_TUI_STATUS_OK

.providers:
        mov     edi, AF_TUI_MODEL_KIND_PROVIDERS
        lea     rsi, [rsp + 16]
        call    af_tm_slot_result
        test    rax, rax
        js      .invalid
        mov     r13, [rsp + 16]
        mov     rdi, r13
        call    af_json_array_count
        mov     [rsp + 24], rax
        xor     r14d, r14d
.provider_loop:
        cmp     r14, [rsp + 24]
        jae     .mcp_begin
        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [rsp + 32]
        call    af_json_array_at
        test    rax, rax
        js      .invalid
        mov     rdi, [rsp + 32]
        call    af_tm_provider_status
        cmp     rax, AF_TUI_STATUS_OK
        je      .provider_ok
        cmp     rax, AF_TUI_STATUS_WARN
        je      .provider_warn
        cmp     rax, AF_TUI_STATUS_OPEN
        je      .provider_open
        inc     qword [r15 + TO_PROVIDER_OFF]
        jmp     .provider_next
.provider_ok:
        inc     qword [r15 + TO_PROVIDER_OK]
        jmp     .provider_next
.provider_warn:
        inc     qword [r15 + TO_PROVIDER_WARN]
        jmp     .provider_next
.provider_open:
        inc     qword [r15 + TO_PROVIDER_OPEN]
.provider_next:
        inc     r14
        jmp     .provider_loop

.mcp_begin:
        mov     edi, AF_TUI_MODEL_KIND_MCP
        lea     rsi, [rsp + 40]
        call    af_tm_slot_result
        test    rax, rax
        js      .invalid
        mov     r13, [rsp + 40]
        mov     rdi, r13
        call    af_json_array_count
        mov     [rsp + 48], rax
        xor     r14d, r14d
.mcp_loop:
        cmp     r14, [rsp + 48]
        jae     .routes
        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [rsp + 56]
        call    af_json_array_at
        test    rax, rax
        js      .invalid
        mov     rdi, [rsp + 56]
        call    af_tm_mcp_status
        cmp     rax, AF_TUI_STATUS_OK
        je      .mcp_ok
        cmp     rax, AF_TUI_STATUS_RUN
        je      .mcp_run
        cmp     rax, AF_TUI_STATUS_FAIL
        je      .mcp_fail
        inc     qword [r15 + TO_MCP_OFF]
        jmp     .mcp_next
.mcp_ok:
        inc     qword [r15 + TO_MCP_OK]
        jmp     .mcp_next
.mcp_run:
        inc     qword [r15 + TO_MCP_RUN]
        jmp     .mcp_next
.mcp_fail:
        inc     qword [r15 + TO_MCP_FAIL]
.mcp_next:
        inc     r14
        jmp     .mcp_loop

.routes:
        mov     edi, AF_TUI_MODEL_KIND_ROUTES
        lea     rsi, [rsp + 64]
        call    af_tm_slot_result
        test    rax, rax
        js      .invalid
        mov     rdi, [rsp + 64]
        call    af_tm_overview_route_rows
        mov     [r15 + TO_ROUTE_COUNT], rax
        mov     rdi, [rsp + 16]
        mov     rsi, [rsp + 40]
        call    af_tm_overview_events
        mov     [r15 + TO_EVENT_COUNT], rax
        mov     rax, r12
        AF_LEAVE
.invalid:
        xor     edi, edi
        call    af_tm_build_invalid
        AF_LEAVE

; ---------------------------------------------------------------------------
; Stable-ID selection.  The dedicated ID bytes are OWNED by this module and
; returned as BORROWED spans.  Row scratch may be rebuilt without invalidating
; the selected ID.  Reorder resolution first searches by ID, then clamps the
; previous index to the nearest surviving row.
; ---------------------------------------------------------------------------
; af_tm_id_span_valid(bytes,len) -> boolean
af_tm_id_span_valid:
        test    rdi, rdi
        jz      .no
        test    rsi, rsi
        jz      .no
        cmp     rsi, AF_CTL_ID_MAX
        ja      .no
        xor     eax, eax
.byte:
        cmp     rax, rsi
        jae     .yes
        movzx   ecx, byte [rdi + rax]
        cmp     cl, 'a'
        jb      .upper
        cmp     cl, 'z'
        jbe     .next
.upper:
        cmp     cl, 'A'
        jb      .digit
        cmp     cl, 'Z'
        jbe     .next
.digit:
        cmp     cl, '0'
        jb      .punct
        cmp     cl, '9'
        jbe     .next
.punct:
        cmp     cl, '-'
        je      .next
        cmp     cl, '_'
        je      .next
        cmp     cl, '.'
        jne     .no
.next:
        inc     rax
        jmp     .byte
.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

af_tm_selected_ptr:
        imul    rdi, AF_CTL_ID_MAX
        lea     rax, [tm_selected_ids]
        add     rax, rdi
        ret

; af_tm_selection_store(screen_index,index,row) -> af_status
af_tm_selection_store:
        AF_ENTER 16
        cmp     rdi, AF_TUI_SCREEN_COUNT
        jae     .invalid
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, [r13 + TR_ID_LEN]
        test    r14, r14
        jz      .not_found
        cmp     r14, AF_CTL_ID_MAX
        ja      .limit
        mov     r15, [r13 + TR_ID_PTR]
        test    r15, r15
        jz      .not_found
        mov     rdi, rbx
        call    af_tm_selected_ptr
        mov     rdi, rax
        mov     rsi, r15
        mov     rdx, r14
        call    af_mem_copy
        lea     rax, [tm_selected_id_lens]
        mov     [rax + rbx * 8], r14
        lea     rax, [tm_selected_indices]
        mov     [rax + rbx * 8], r12
        AF_LEAVE_OK
.not_found:
        lea     rax, [tm_selected_id_lens]
        mov     qword [rax + rbx * 8], 0
        AF_LEAVE_ERR AF_E_NOTFOUND
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_tm_sync_selection_array(screen_index,json_array) -> af_status
;
; Runs at successful set_frame commit so selected_id is already correct even
; before the next render.  This matters because provider refresh immediately
; issues providers.get.  Only the first 64 visible rows participate.
af_tm_sync_selection_array:
        AF_ENTER 80
        cmp     rdi, AF_TUI_SCREEN_COUNT
        jae     .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, r12
        call    af_json_array_count
        test    rax, rax
        jz      .clear
        cmp     rax, AF_TUI_MODEL_MAX_ROWS
        jbe     .count_ok
        mov     rax, AF_TUI_MODEL_MAX_ROWS
.count_ok:
        mov     r13, rax
        lea     rax, [tm_selected_indices]
        mov     r14, [rax + rbx * 8]
        lea     rax, [tm_selected_id_lens]
        mov     r15, [rax + rbx * 8]
        test    r15, r15
        jz      .fallback
        mov     rdi, rbx
        call    af_tm_selected_ptr
        mov     [rsp], rax
        xor     ecx, ecx
.find:
        cmp     rcx, r13
        jae     .fallback
        mov     [rsp + 8], rcx
        mov     rdi, r12
        mov     rsi, rcx
        lea     rdx, [rsp + 16]
        call    af_json_array_at
        test    rax, rax
        js      .next
        mov     rdi, [rsp + 16]
        lea     rsi, [tm_k_id]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_string
        test    rax, rax
        js      .next
        cmp     [rsp + 32], r15
        jne     .next
        mov     rdi, [rsp + 24]
        mov     rsi, [rsp + 32]
        call    af_tm_id_span_valid
        test    rax, rax
        jz      .next
        mov     rdi, [rsp]
        mov     rsi, [rsp + 24]
        mov     rdx, r15
        call    af_mem_eq
        test    rax, rax
        jnz     .found
.next:
        mov     rcx, [rsp + 8]
        inc     rcx
        jmp     .find
.found:
        mov     rcx, [rsp + 8]
        lea     rax, [tm_selected_indices]
        mov     [rax + rbx * 8], rcx
        AF_LEAVE_OK

.fallback:
        cmp     r14, r13
        jb      .index_ready
        mov     r14, r13
        dec     r14
.index_ready:
        mov     rdi, r12
        mov     rsi, r14
        lea     rdx, [rsp + 16]
        call    af_json_array_at
        test    rax, rax
        js      .clear
        mov     rdi, [rsp + 16]
        lea     rsi, [tm_k_id]
        lea     rdx, [rsp + 24]
        lea     rcx, [rsp + 32]
        call    af_json_get_string
        test    rax, rax
        js      .clear
        mov     rdi, [rsp + 24]
        mov     rsi, [rsp + 32]
        call    af_tm_id_span_valid
        test    rax, rax
        jz      .clear
        mov     rax, [rsp + 24]
        mov     [rsp + 40 + TR_ID_PTR], rax
        mov     rax, [rsp + 32]
        mov     [rsp + 40 + TR_ID_LEN], rax
        mov     rdi, rbx
        mov     rsi, r14
        lea     rdx, [rsp + 40]
        call    af_tm_selection_store
        AF_LEAVE

.clear:
        lea     rax, [tm_selected_id_lens]
        mov     qword [rax + rbx * 8], 0
        lea     rax, [tm_selected_indices]
        mov     qword [rax + rbx * 8], 0
        AF_LEAVE_ERR AF_E_NOTFOUND
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_tm_rebind_detail(screen_index,model) -> void
;
; Provider and MCP details use cell 1 (display name); route details use cell 0
; (alias).  Keeping this binding next to selection mutation prevents the focus
; marker, action stable ID, and inspector title from describing different rows.
af_tm_rebind_detail:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        test    r12, r12
        jz      .done
        mov     r13, [r12 + TM_SELECTED_INDEX]
        cmp     r13, [r12 + TM_ROW_COUNT]
        jae     .done
        mov     rax, r13
        imul    rax, TR_SIZE
        add     rax, [r12 + TM_ROWS]
        mov     r14, [rax + TR_CELLS]
        test    r14, r14
        jz      .done
        cmp     rbx, 1                 ; providers
        je      .name
        cmp     rbx, 4                 ; MCP
        je      .name
        cmp     rbx, 2                 ; routes
        jne     .done
        cmp     qword [rax + TR_CELL_COUNT], 1
        jb      .done
        jmp     .bind
.name:
        cmp     qword [rax + TR_CELL_COUNT], 2
        jb      .done
        add     r14, TT_SIZE
.bind:
        mov     rax, [r14 + TT_PTR]
        mov     [r12 + TM_DETAIL_TITLE_PTR], rax
        mov     rax, [r14 + TT_LEN]
        mov     [r12 + TM_DETAIL_TITLE_LEN], rax
.done:
        AF_LEAVE

; af_tm_resolve_selection(screen_index,model) -> af_status
af_tm_resolve_selection:
        AF_ENTER 48
        cmp     rdi, AF_TUI_SCREEN_COUNT
        jae     .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, [r12 + TM_ROW_COUNT]
        test    r13, r13
        jz      .empty
        cmp     r13, AF_TUI_MODEL_MAX_ROWS
        ja      .limit
        mov     r14, [r12 + TM_ROWS]
        test    r14, r14
        jz      .invalid
        lea     rax, [tm_selected_indices]
        mov     r15, [rax + rbx * 8]
        lea     rax, [tm_selected_id_lens]
        mov     rax, [rax + rbx * 8]
        mov     [rsp], rax
        test    rax, rax
        jz      .fallback
        mov     rdi, rbx
        call    af_tm_selected_ptr
        mov     [rsp + 8], rax
        xor     ecx, ecx
.find:
        cmp     rcx, r13
        jae     .fallback
        mov     rax, rcx
        imul    rax, TR_SIZE
        add     rax, r14
        mov     rdx, [rax + TR_ID_LEN]
        cmp     rdx, [rsp]
        jne     .next
        mov     rdx, [rax + TR_ID_PTR]
        test    rdx, rdx
        jz      .next
        mov     [rsp + 16], rcx
        mov     rdi, [rsp + 8]
        mov     rsi, rdx
        mov     rdx, [rsp]
        call    af_mem_eq
        test    rax, rax
        jnz     .found
        mov     rcx, [rsp + 16]
.next:
        inc     rcx
        jmp     .find
.found:
        mov     rcx, [rsp + 16]
        lea     rax, [tm_selected_indices]
        mov     [rax + rbx * 8], rcx
        mov     [r12 + TM_SELECTED_INDEX], rcx
        mov     rdi, rbx
        mov     rsi, r12
        call    af_tm_rebind_detail
        AF_LEAVE_OK
.fallback:
        cmp     r15, r13
        jb      .index_ready
        mov     r15, r13
        dec     r15
.index_ready:
        mov     rax, r15
        imul    rax, TR_SIZE
        add     rax, r14
        mov     rdi, rbx
        mov     rsi, r15
        mov     rdx, rax
        call    af_tm_selection_store
        test    rax, rax
        js      .empty_model
        mov     [r12 + TM_SELECTED_INDEX], r15
        mov     rdi, rbx
        mov     rsi, r12
        call    af_tm_rebind_detail
        AF_LEAVE_OK
.empty:
        lea     rax, [tm_selected_id_lens]
        mov     qword [rax + rbx * 8], 0
.empty_model:
        mov     qword [r12 + TM_SELECTED_INDEX], -1
        AF_LEAVE_ERR AF_E_NOTFOUND
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_tui_model_select_next(rdi=screen_id) -> af_status
;
; Mutates only the model-owned focus state.  The next selected_id call returns
; a BORROWED stable-ID span from tm_selected_ids.
        global af_tui_model_select_next
af_tui_model_select_next:
        AF_ENTER 16
        cmp     rdi, AF_TUI_SCREEN_OVERVIEW
        jb      .invalid
        cmp     rdi, AF_TUI_SCREEN_SETTINGS
        ja      .invalid
        dec     rdi
        mov     rbx, rdi
        call    af_tm_model_ptr
        mov     r12, rax
        mov     r13, [r12 + TM_ROW_COUNT]
        test    r13, r13
        jz      .not_found
        cmp     r13, AF_TUI_MODEL_MAX_ROWS
        ja      .limit
        lea     rax, [tm_selected_indices]
        mov     r14, [rax + rbx * 8]
        inc     r14
        cmp     r14, r13
        jb      .index_ready
        xor     r14d, r14d
.index_ready:
        mov     rax, r14
        imul    rax, TR_SIZE
        add     rax, [r12 + TM_ROWS]
        mov     rdi, rbx
        mov     rsi, r14
        mov     rdx, rax
        call    af_tm_selection_store
        test    rax, rax
        js      .done
        mov     [r12 + TM_SELECTED_INDEX], r14
        mov     rdi, rbx
        mov     rsi, r12
        call    af_tm_rebind_detail
.done:
        AF_LEAVE
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_tui_model_select_prev(rdi=screen_id) -> af_status
;
; Symmetric with select_next. Selection wraps to the final row and updates the
; same owned stable-ID span, so a later refresh or mutation resolves the row by
; identity rather than by its former array index.
        global af_tui_model_select_prev
af_tui_model_select_prev:
        AF_ENTER 16
        cmp     rdi, AF_TUI_SCREEN_OVERVIEW
        jb      .invalid
        cmp     rdi, AF_TUI_SCREEN_SETTINGS
        ja      .invalid
        dec     rdi
        mov     rbx, rdi
        call    af_tm_model_ptr
        mov     r12, rax
        mov     r13, [r12 + TM_ROW_COUNT]
        test    r13, r13
        jz      .not_found
        cmp     r13, AF_TUI_MODEL_MAX_ROWS
        ja      .limit
        lea     rax, [tm_selected_indices]
        mov     r14, [rax + rbx * 8]
        cmp     r14, r13
        jb      .index_in_range
        xor     r14d, r14d
.index_in_range:
        test    r14, r14
        jnz     .decrement
        mov     r14, r13
.decrement:
        dec     r14
        mov     rax, r14
        imul    rax, TR_SIZE
        add     rax, [r12 + TM_ROWS]
        mov     rdi, rbx
        mov     rsi, r14
        mov     rdx, rax
        call    af_tm_selection_store
        test    rax, rax
        js      .done
        mov     [r12 + TM_SELECTED_INDEX], r14
        mov     rdi, rbx
        mov     rsi, r12
        call    af_tm_rebind_detail
.done:
        AF_LEAVE
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_tui_model_selected_id(rdi=screen_id,rsi=&ptr,rdx=&len) -> af_status
;
; `*ptr` is BORROWED and valid until reset, another successful set_frame for
; the same list kind, or a selection mutation.  Output pointers are written
; only on success.
        global af_tui_model_selected_id
af_tui_model_selected_id:
        AF_ENTER 16
        cmp     rdi, AF_TUI_SCREEN_OVERVIEW
        jb      .invalid
        cmp     rdi, AF_TUI_SCREEN_SETTINGS
        ja      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        dec     rdi
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        lea     rax, [tm_selected_id_lens]
        mov     r14, [rax + rbx * 8]
        test    r14, r14
        jz      .not_found
        mov     rdi, rbx
        call    af_tm_selected_ptr
        mov     [r12], rax
        mov     [r13], r14
        AF_LEAVE_OK
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_tui_model_build(rdi=screen_id,rsi=connection_state) -> TUI_MODEL *
;
; The returned process-local pointer is BORROWED until reset, set_frame, or a
; subsequent build for the same screen.  NULL is returned only for an invalid
; screen ID.  Invalid/missing control data produces a non-NULL disconnected,
; actionable model so the renderer never dereferences daemon-owned memory.
; ---------------------------------------------------------------------------
        global af_tui_model_build
af_tui_model_build:
        AF_ENTER 32
        cmp     rdi, AF_TUI_SCREEN_OVERVIEW
        jb      .invalid
        cmp     rdi, AF_TUI_SCREEN_SETTINGS
        ja      .invalid
        mov     rbx, rdi
        dec     rbx
        mov     r12, rsi
        cmp     r12, AF_TUI_CONN_DISCONNECTED
        jbe     .connection_ok
        mov     r12, AF_TUI_CONN_DISCONNECTED
.connection_ok:
        lea     rax, [tm_dirty]
        cmp     qword [rax + rbx * 8], 0
        jne     .rebuild
        mov     rdi, rbx
        call    af_tm_model_ptr
        test    qword [rax + TM_FLAGS], 1
        jnz     .cached_invalid
        mov     [rax + TM_CONNECTION], r12
        AF_LEAVE
.cached_invalid:
        mov     qword [rax + TM_CONNECTION], AF_TUI_CONN_DISCONNECTED
        AF_LEAVE

.rebuild:
        cmp     rbx, 0
        je      .overview
        cmp     rbx, 1
        je      .providers
        cmp     rbx, 2
        je      .routes
        cmp     rbx, 3
        je      .requests
        cmp     rbx, 4
        je      .mcp
        cmp     rbx, 5
        je      .logs
        mov     rdi, r12
        call    af_tm_build_settings
        jmp     .built
.overview:
        mov     rdi, r12
        call    af_tm_build_overview
        jmp     .built
.providers:
        mov     rdi, r12
        call    af_tm_build_providers
        jmp     .selection
.routes:
        mov     rdi, r12
        call    af_tm_build_routes
        jmp     .selection
.requests:
        mov     rdi, r12
        call    af_tm_build_requests
        jmp     .built
.mcp:
        mov     rdi, r12
        call    af_tm_build_mcp
        jmp     .selection
.logs:
        mov     rdi, r12
        call    af_tm_build_logs
        jmp     .built
.selection:
        mov     r13, rax
        mov     rdi, rbx
        mov     rsi, r13
        call    af_tm_resolve_selection
        mov     rax, r13
.built:
        mov     r13, rax
        lea     rax, [tm_dirty]
        mov     qword [rax + rbx * 8], 0
        mov     rax, r13
        AF_LEAVE
.invalid:
        xor     eax, eax
        AF_LEAVE
