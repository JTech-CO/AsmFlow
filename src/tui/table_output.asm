; AsmFlow -- deterministic non-interactive table rendering for asmflowctl.
;
; Rendering consumes only a bounded control response.  Strings are borrowed
; from the parsed document and are escaped before terminal output: no daemon or
; MCP supplied ESC/control byte is ever written raw.  Known read methods use a
; stable tab-separated schema; additive or unknown methods fall back to the
; exact JSON envelope followed by LF.

        bits 64
        default rel

%include "asmflow.inc"
%include "control.inc"
%include "control_client.inc"
%include "json.inc"

        extern af_buf_init
        extern af_buf_free
        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_append_u64
        extern af_buf_data
        extern af_buf_len

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

        extern af_cstr_len
        extern af_mem_eq
        extern af_write_all

        section .rodata

tbl_hex: db "0123456789abcdef"
tbl_dash: db "-"
tbl_space: db " "
tbl_tab: db 9
tbl_lf: db 10
tbl_slash: db "/"
tbl_ms: db " ms"
tbl_status_ok: db "[OK]"
tbl_status_warn: db "[WARN]"
tbl_status_open: db "[OPEN]"
tbl_status_off: db "[OFF]"
tbl_status_unknown: db "[?]"
tbl_circuit_closed: db "closed"
tbl_circuit_degraded: db "degraded"
tbl_circuit_open: db "open"
tbl_circuit_half_open: db "half-open"
tbl_circuit_disabled: db "disabled"
tbl_health_healthy: db "healthy"
tbl_health_healthy_len equ $ - tbl_health_healthy
tbl_health_degraded: db "degraded"
tbl_health_degraded_len equ $ - tbl_health_degraded
tbl_health_open: db "open"
tbl_health_open_len equ $ - tbl_health_open
tbl_health_half_open: db "half_open"
tbl_health_half_open_len equ $ - tbl_health_half_open
tbl_health_disabled: db "disabled"
tbl_health_disabled_len equ $ - tbl_health_disabled
tbl_true: db "true"
tbl_false: db "false"
tbl_esc_bs: db "\\"
tbl_esc_n: db "\n"
tbl_esc_r: db "\r"
tbl_esc_t: db "\t"

tbl_m_system_version:  db "system.version", 0
tbl_m_system_snapshot: db "system.snapshot", 0
tbl_m_providers_list:  db "providers.list", 0
tbl_m_routes_list:     db "routes.list", 0
tbl_m_mcp_list:        db "mcp.list", 0

tbl_k_ok: db "ok", 0
tbl_k_result: db "result", 0
tbl_k_error: db "error", 0
tbl_k_code: db "code", 0
tbl_k_message: db "message", 0
tbl_k_field: db "field", 0

tbl_k_version: db "version", 0
tbl_k_target: db "target", 0
tbl_k_build: db "build", 0
tbl_k_protocol_version: db "protocol_version", 0
tbl_k_revision: db "revision", 0
tbl_k_ready: db "ready", 0
tbl_k_database: db "database", 0
tbl_k_uptime_ms: db "uptime_ms", 0
tbl_k_started_at_ms: db "started_at_ms", 0
tbl_k_reload_count: db "reload_count", 0
tbl_k_counts: db "counts", 0
tbl_k_providers: db "providers", 0
tbl_k_routes: db "routes", 0
tbl_k_mcp_servers: db "mcp_servers", 0
tbl_k_connections: db "connections", 0

tbl_k_health: db "health", 0
tbl_k_enabled_provider: db "enabled", 0
tbl_k_operator_disabled: db "operator_disabled", 0
tbl_k_id: db "id", 0
tbl_k_display_name: db "display_name", 0
tbl_k_adapter: db "adapter", 0
tbl_k_active_requests: db "active_requests", 0
tbl_k_max_concurrency: db "max_concurrency", 0
tbl_k_observed_latency: db "observed_latency_us", 0

tbl_k_model_alias: db "model_alias", 0
tbl_k_policy: db "policy", 0
tbl_k_targets: db "targets", 0
tbl_k_enabled: db "enabled", 0
tbl_k_fallback: db "fallback", 0
tbl_k_max_attempts: db "max_attempts", 0

tbl_k_state: db "state", 0
tbl_k_transport: db "transport", 0
tbl_k_era: db "era", 0
tbl_k_tool_count: db "tool_count", 0
tbl_k_resource_count: db "resource_count", 0
tbl_k_restarts: db "restarts", 0

tbl_h_field: db "FIELD", 9, "VALUE", 10
tbl_h_field_len equ $ - tbl_h_field
tbl_h_error: db "STATUS", 9, "CODE", 9, "MESSAGE", 9, "FIELD", 10
tbl_h_error_len equ $ - tbl_h_error
tbl_h_providers:
        db "STATUS NAME            ADAPTER           ACTIVE/MAX LATENCY  CIRCUIT", 10
tbl_h_providers_len equ $ - tbl_h_providers
tbl_h_routes:
        db "ALIAS", 9, "POLICY", 9, "TARGETS", 9, "ENABLED", 9
        db "MAX_ATTEMPTS", 10
tbl_h_routes_len equ $ - tbl_h_routes
tbl_h_mcp:
        db "STATUS", 9, "ID", 9, "NAME", 9, "TRANSPORT", 9, "ERA", 9
        db "VERSION", 9, "TOOLS", 9, "RESOURCES", 9, "RESTARTS", 10
tbl_h_mcp_len equ $ - tbl_h_mcp

tbl_l_version: db "version", 9
tbl_l_version_len equ $ - tbl_l_version
tbl_l_target: db "target", 9
tbl_l_target_len equ $ - tbl_l_target
tbl_l_build: db "build", 9
tbl_l_build_len equ $ - tbl_l_build
tbl_l_protocol: db "protocol_version", 9
tbl_l_protocol_len equ $ - tbl_l_protocol
tbl_l_revision: db "revision", 9
tbl_l_revision_len equ $ - tbl_l_revision
tbl_l_ready: db "ready", 9
tbl_l_ready_len equ $ - tbl_l_ready
tbl_l_database: db "database", 9
tbl_l_database_len equ $ - tbl_l_database
tbl_l_uptime: db "uptime_ms", 9
tbl_l_uptime_len equ $ - tbl_l_uptime
tbl_l_started: db "started_at_ms", 9
tbl_l_started_len equ $ - tbl_l_started
tbl_l_reload: db "reload_count", 9
tbl_l_reload_len equ $ - tbl_l_reload
tbl_l_providers: db "providers", 9
tbl_l_providers_len equ $ - tbl_l_providers
tbl_l_routes: db "routes", 9
tbl_l_routes_len equ $ - tbl_l_routes
tbl_l_mcp: db "mcp_servers", 9
tbl_l_mcp_len equ $ - tbl_l_mcp
tbl_l_connections: db "connections", 9
tbl_l_connections_len equ $ - tbl_l_connections

        section .text

; The builders below use rbx as the output af_buffer and have one `.done`
; label.  These macros keep every append checked without hiding any policy.
%macro TBL_APPEND_STATIC 2
        mov     rdi, rbx
        lea     rsi, [%1]
        mov     rdx, %2
        call    af_buf_append
        test    rax, rax
        js      .done
%endmacro

%macro TBL_APPEND_TAB 0
        TBL_APPEND_STATIC tbl_tab, 1
%endmacro

%macro TBL_APPEND_LF 0
        TBL_APPEND_STATIC tbl_lf, 1
%endmacro

; ---------------------------------------------------------------------------
; af_tbl_method_eq(method, len, static_cstr) -> i64
; ---------------------------------------------------------------------------
af_tbl_method_eq:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, r13
        call    af_cstr_len
        cmp     rax, r12
        jne     .no
        mov     rdi, rbx
        mov     rsi, r13
        mov     rdx, r12
        call    af_mem_eq
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_tbl_escape(af_buffer *out, const u8 *text, u64 len) -> af_status
;
; UTF-8 bytes >= 0x80 remain unchanged.  ASCII controls, DEL, backslash, and
; table delimiters are escaped so remote text cannot control the terminal or
; create extra rows/columns.
; ---------------------------------------------------------------------------
af_tbl_escape:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        xor     r14d, r14d
.loop:
        cmp     r14, r13
        jae     .ok
        movzx   eax, byte [r12 + r14]
        cmp     al, 10
        je      .newline
        cmp     al, 13
        je      .return
        cmp     al, 9
        je      .tab
        cmp     al, 0x5c
        je      .backslash
        cmp     al, 0x20
        jb      .hex
        cmp     al, 0x7f
        je      .hex
        mov     rdi, rbx
        mov     rsi, rax
        call    af_buf_append_byte
        jmp     .checked
.newline:
        mov     rdi, rbx
        lea     rsi, [tbl_esc_n]
        mov     rdx, 2
        call    af_buf_append
        jmp     .checked
.return:
        mov     rdi, rbx
        lea     rsi, [tbl_esc_r]
        mov     rdx, 2
        call    af_buf_append
        jmp     .checked
.tab:
        mov     rdi, rbx
        lea     rsi, [tbl_esc_t]
        mov     rdx, 2
        call    af_buf_append
        jmp     .checked
.backslash:
        mov     rdi, rbx
        lea     rsi, [tbl_esc_bs]
        mov     rdx, 2
        call    af_buf_append
        jmp     .checked
.hex:
        mov     byte [rsp], 0x5c
        mov     byte [rsp + 1], 'x'
        mov     ecx, eax
        shr     ecx, 4
        and     ecx, 0x0f
        lea     rdx, [tbl_hex]
        mov     cl, [rdx + rcx]
        mov     [rsp + 2], cl
        and     eax, 0x0f
        mov     al, [rdx + rax]
        mov     [rsp + 3], al
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, 4
        call    af_buf_append
.checked:
        test    rax, rax
        js      .done
        inc     r14
        jmp     .loop
.ok:
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; Scalar append helpers.  A missing or differently typed additive field is
; rendered as '-', keeping old clients useful against a newer daemon.
; ---------------------------------------------------------------------------
af_tbl_member_string:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, r12
        mov     rsi, r13
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_string
        test    rax, rax
        js      .dash
        mov     rdi, rbx
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_tbl_escape
        AF_LEAVE
.dash:
        mov     rdi, rbx
        lea     rsi, [tbl_dash]
        mov     rdx, 1
        call    af_buf_append
        AF_LEAVE

af_tbl_append_i64:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        test    r12, r12
        jns     .magnitude
        mov     rdi, rbx
        mov     rsi, '-'
        call    af_buf_append_byte
        test    rax, rax
        js      .done
        neg     r12
.magnitude:
        mov     rdi, rbx
        mov     rsi, r12
        call    af_buf_append_u64
.done:
        AF_LEAVE

af_tbl_member_int:
        AF_ENTER 16
        mov     rbx, rdi
        mov     rdi, rsi
        mov     rsi, rdx
        lea     rdx, [rsp]
        call    af_json_get_integer
        test    rax, rax
        js      .dash
        mov     rdi, rbx
        mov     rsi, [rsp]
        call    af_tbl_append_i64
        AF_LEAVE
.dash:
        mov     rdi, rbx
        lea     rsi, [tbl_dash]
        mov     rdx, 1
        call    af_buf_append
        AF_LEAVE

af_tbl_member_bool:
        AF_ENTER 16
        mov     rbx, rdi
        mov     rdi, rsi
        mov     rsi, rdx
        lea     rdx, [rsp]
        call    af_json_get_bool
        test    rax, rax
        js      .dash
        lea     rsi, [tbl_false]
        mov     rdx, 5
        cmp     qword [rsp], 0
        je      .append
        lea     rsi, [tbl_true]
        mov     rdx, 4
.append:
        mov     rdi, rbx
        call    af_buf_append
        AF_LEAVE
.dash:
        mov     rdi, rbx
        lea     rsi, [tbl_dash]
        mov     rdx, 1
        call    af_buf_append
        AF_LEAVE

af_tbl_member_array_count:
        AF_ENTER 32
        mov     rbx, rdi
        mov     rdi, rsi
        mov     rsi, rdx
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_json_get_array
        test    rax, rax
        js      .dash
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        call    af_buf_append_u64
        AF_LEAVE
.dash:
        mov     rdi, rbx
        lea     rsi, [tbl_dash]
        mov     rdx, 1
        call    af_buf_append
        AF_LEAVE

; ---------------------------------------------------------------------------
; system.version table.
; ---------------------------------------------------------------------------
af_tbl_build_version:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        TBL_APPEND_STATIC tbl_h_field, tbl_h_field_len
        TBL_APPEND_STATIC tbl_l_version, tbl_l_version_len
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_version]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_target, tbl_l_target_len
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_target]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_build, tbl_l_build_len
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_build]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_protocol, tbl_l_protocol_len
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_protocol_version]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; system.snapshot table.
; ---------------------------------------------------------------------------
af_tbl_build_snapshot:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        TBL_APPEND_STATIC tbl_h_field, tbl_h_field_len
        TBL_APPEND_STATIC tbl_l_revision, tbl_l_revision_len
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_revision]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_ready, tbl_l_ready_len
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_ready]
        call    af_tbl_member_bool
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_database, tbl_l_database_len
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_database]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_uptime, tbl_l_uptime_len
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_uptime_ms]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_started, tbl_l_started_len
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_started_at_ms]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_reload, tbl_l_reload_len
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_reload_count]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_LF

        mov     rdi, r12
        lea     rsi, [tbl_k_counts]
        lea     rdx, [rsp]
        call    af_json_get_object
        test    rax, rax
        js      .no_counts
        mov     r13, [rsp]
        TBL_APPEND_STATIC tbl_l_providers, tbl_l_providers_len
        mov     rdi, rbx
        mov     rsi, r13
        lea     rdx, [tbl_k_providers]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_routes, tbl_l_routes_len
        mov     rdi, rbx
        mov     rsi, r13
        lea     rdx, [tbl_k_routes]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_mcp, tbl_l_mcp_len
        mov     rdi, rbx
        mov     rsi, r13
        lea     rdx, [tbl_k_mcp_servers]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        TBL_APPEND_STATIC tbl_l_connections, tbl_l_connections_len
        mov     rdi, rbx
        mov     rsi, r13
        lea     rdx, [tbl_k_connections]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_LF
.no_counts:
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; providers.list helpers and table.
;
; Provider columns intentionally use byte-stable fixed starts (0,7,23,41,52,
; 61).  Strings longer than a column receive one separating space rather than
; being truncated.  This keeps the non-interactive contract deterministic and
; preserves every escaped operator-visible byte.
; ---------------------------------------------------------------------------
%define TBL_HEALTH_UNKNOWN   0
%define TBL_HEALTH_HEALTHY   1
%define TBL_HEALTH_DEGRADED  2
%define TBL_HEALTH_OPEN      3
%define TBL_HEALTH_HALF_OPEN 4
%define TBL_HEALTH_DISABLED  5

; af_tbl_health_code(const char *text, u64 len) -> enum
af_tbl_health_code:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        cmp     r12, tbl_health_healthy_len
        jne     .degraded
        mov     rdi, rbx
        lea     rsi, [tbl_health_healthy]
        mov     rdx, tbl_health_healthy_len
        call    af_mem_eq
        test    rax, rax
        jnz     .healthy_match
.degraded:
        cmp     r12, tbl_health_degraded_len
        jne     .open
        mov     rdi, rbx
        lea     rsi, [tbl_health_degraded]
        mov     rdx, tbl_health_degraded_len
        call    af_mem_eq
        test    rax, rax
        jnz     .degraded_match
.open:
        cmp     r12, tbl_health_open_len
        jne     .half_open
        mov     rdi, rbx
        lea     rsi, [tbl_health_open]
        mov     rdx, tbl_health_open_len
        call    af_mem_eq
        test    rax, rax
        jnz     .open_match
.half_open:
        cmp     r12, tbl_health_half_open_len
        jne     .disabled
        mov     rdi, rbx
        lea     rsi, [tbl_health_half_open]
        mov     rdx, tbl_health_half_open_len
        call    af_mem_eq
        test    rax, rax
        jnz     .half_open_match
.disabled:
        cmp     r12, tbl_health_disabled_len
        jne     .unknown
        mov     rdi, rbx
        lea     rsi, [tbl_health_disabled]
        mov     rdx, tbl_health_disabled_len
        call    af_mem_eq
        test    rax, rax
        jnz     .disabled_match
.unknown:
        xor     eax, eax
        AF_LEAVE
.healthy_match:
        mov     eax, TBL_HEALTH_HEALTHY
        AF_LEAVE
.degraded_match:
        mov     eax, TBL_HEALTH_DEGRADED
        AF_LEAVE
.open_match:
        mov     eax, TBL_HEALTH_OPEN
        AF_LEAVE
.half_open_match:
        mov     eax, TBL_HEALTH_HALF_OPEN
        AF_LEAVE
.disabled_match:
        mov     eax, TBL_HEALTH_DISABLED
        AF_LEAVE

; af_tbl_provider_off(json_t *provider) -> boolean
af_tbl_provider_off:
        AF_ENTER 16
        mov     rbx, rdi
        mov     rdi, rbx
        lea     rsi, [tbl_k_enabled_provider]
        lea     rdx, [rsp]
        call    af_json_get_bool
        test    rax, rax
        js      .operator
        cmp     qword [rsp], 0
        je      .yes
.operator:
        mov     rdi, rbx
        lea     rsi, [tbl_k_operator_disabled]
        lea     rdx, [rsp]
        call    af_json_get_bool
        test    rax, rax
        js      .no
        cmp     qword [rsp], 0
        jne     .yes
.no:
        xor     eax, eax
        AF_LEAVE
.yes:
        mov     eax, 1
        AF_LEAVE

; af_tbl_provider_status(out, health_code, off) -> af_status
af_tbl_provider_status:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        test    rdx, rdx
        jnz     .off
        cmp     r12, TBL_HEALTH_DISABLED
        je      .off
        cmp     r12, TBL_HEALTH_HEALTHY
        je      .ok
        cmp     r12, TBL_HEALTH_OPEN
        je      .open
        cmp     r12, TBL_HEALTH_DEGRADED
        je      .warn
        cmp     r12, TBL_HEALTH_HALF_OPEN
        je      .warn
        lea     rsi, [tbl_status_unknown]
        mov     rdx, 3
        jmp     .append
.ok:
        lea     rsi, [tbl_status_ok]
        mov     rdx, 4
        jmp     .append
.warn:
        lea     rsi, [tbl_status_warn]
        mov     rdx, 6
        jmp     .append
.open:
        lea     rsi, [tbl_status_open]
        mov     rdx, 6
        jmp     .append
.off:
        lea     rsi, [tbl_status_off]
        mov     rdx, 5
.append:
        mov     rdi, rbx
        call    af_buf_append
        AF_LEAVE

; af_tbl_pad_column(out, row_start_len, target_column) -> af_status
af_tbl_pad_column:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, rbx
        call    af_buf_len
        sub     rax, r12
        jc      .invalid
        cmp     rax, r13
        je      .ok
        ja      .one
        sub     r13, rax
.padding:
        mov     rdi, rbx
        mov     rsi, ' '
        call    af_buf_append_byte
        test    rax, rax
        js      .done
        dec     r13
        jnz     .padding
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.one:
        mov     rdi, rbx
        mov     rsi, ' '
        call    af_buf_append_byte
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INTERNAL

; af_tbl_provider_latency(out, provider) -> af_status
af_tbl_provider_latency:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, r12
        lea     rsi, [tbl_k_observed_latency]
        lea     rdx, [rsp]
        call    af_json_get_integer
        test    rax, rax
        js      .dash
        mov     rax, [rsp]
        test    rax, rax
        jle     .dash
        xor     edx, edx
        mov     ecx, 1000
        div     rcx
        mov     r13, rdx
        mov     rdi, rbx
        mov     rsi, rax
        call    af_buf_append_u64
        test    rax, rax
        js      .done
        test    r13, r13
        jz      .unit
        mov     rdi, rbx
        mov     rsi, '.'
        call    af_buf_append_byte
        test    rax, rax
        js      .done
        mov     rax, r13
        xor     edx, edx
        mov     ecx, 100
        div     rcx
        add     al, '0'
        mov     [rsp + 8], al
        mov     rax, rdx
        xor     edx, edx
        mov     ecx, 10
        div     rcx
        add     al, '0'
        mov     [rsp + 9], al
        add     dl, '0'
        mov     [rsp + 10], dl
        mov     r14, 3
.trim:
        cmp     byte [rsp + 7 + r14], '0'
        jne     .fraction
        dec     r14
        jnz     .trim
.fraction:
        mov     rdi, rbx
        lea     rsi, [rsp + 8]
        mov     rdx, r14
        call    af_buf_append
        test    rax, rax
        js      .done
.unit:
        mov     rdi, rbx
        lea     rsi, [tbl_ms]
        mov     rdx, 3
        call    af_buf_append
        jmp     .done
.dash:
        mov     rdi, rbx
        lea     rsi, [tbl_dash]
        mov     rdx, 1
        call    af_buf_append
.done:
        AF_LEAVE

; af_tbl_provider_circuit(out, provider, health_code, off) -> af_status
af_tbl_provider_circuit:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        test    rcx, rcx
        jnz     .disabled
        cmp     r13, TBL_HEALTH_DISABLED
        je      .disabled
        cmp     r13, TBL_HEALTH_HEALTHY
        je      .closed
        cmp     r13, TBL_HEALTH_DEGRADED
        je      .degraded
        cmp     r13, TBL_HEALTH_OPEN
        je      .open
        cmp     r13, TBL_HEALTH_HALF_OPEN
        je      .half_open
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_health]
        call    af_tbl_member_string
        AF_LEAVE
.closed:
        lea     rsi, [tbl_circuit_closed]
        mov     rdx, 6
        jmp     .append
.degraded:
        lea     rsi, [tbl_circuit_degraded]
        mov     rdx, 8
        jmp     .append
.open:
        lea     rsi, [tbl_circuit_open]
        mov     rdx, 4
        jmp     .append
.half_open:
        lea     rsi, [tbl_circuit_half_open]
        mov     rdx, 9
        jmp     .append
.disabled:
        lea     rsi, [tbl_circuit_disabled]
        mov     rdx, 8
.append:
        mov     rdi, rbx
        call    af_buf_append
        AF_LEAVE

af_tbl_build_providers:
        AF_ENTER 64
        mov     rbx, rdi
        mov     r12, rsi
        TBL_APPEND_STATIC tbl_h_providers, tbl_h_providers_len
        mov     rdi, r12
        call    af_json_array_count
        mov     r13, rax
        xor     r14d, r14d
.row:
        cmp     r14, r13
        jae     .ok
        mov     rdi, rbx
        call    af_buf_len
        mov     [rsp + 8], rax
        mov     rdi, r12
        mov     rsi, r14
        lea     rdx, [rsp]
        call    af_json_array_at
        test    rax, rax
        js      .invalid
        mov     r15, [rsp]
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], 0
        mov     rdi, r15
        lea     rsi, [tbl_k_health]
        lea     rdx, [rsp + 16]
        lea     rcx, [rsp + 24]
        call    af_json_get_string
        test    rax, rax
        js      .health_ready
        mov     rdi, [rsp + 16]
        mov     rsi, [rsp + 24]
        call    af_tbl_health_code
        mov     [rsp + 32], rax
        jmp     .off_flag
.health_ready:
        mov     qword [rsp + 32], TBL_HEALTH_UNKNOWN
.off_flag:
        mov     rdi, r15
        call    af_tbl_provider_off
        mov     [rsp + 40], rax
        mov     rdi, rbx
        mov     rsi, [rsp + 32]
        mov     rdx, [rsp + 40]
        call    af_tbl_provider_status
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        mov     rdx, 7
        call    af_tbl_pad_column
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [tbl_k_display_name]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        mov     rdx, 23
        call    af_tbl_pad_column
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [tbl_k_adapter]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        mov     rdx, 41
        call    af_tbl_pad_column
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [tbl_k_active_requests]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_STATIC tbl_slash, 1
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [tbl_k_max_concurrency]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        mov     rdx, 52
        call    af_tbl_pad_column
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r15
        call    af_tbl_provider_latency
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        mov     rdx, 61
        call    af_tbl_pad_column
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, r15
        mov     rdx, [rsp + 32]
        mov     rcx, [rsp + 40]
        call    af_tbl_provider_circuit
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        inc     r14
        jmp     .row
.invalid:
        mov     rax, AF_E_INVALID
        jmp     .done
.ok:
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; routes.list table.
; ---------------------------------------------------------------------------
af_tbl_build_routes:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        TBL_APPEND_STATIC tbl_h_routes, tbl_h_routes_len
        mov     rdi, r12
        call    af_json_array_count
        mov     r13, rax
        xor     r14d, r14d
.row:
        cmp     r14, r13
        jae     .ok
        mov     rdi, r12
        mov     rsi, r14
        lea     rdx, [rsp]
        call    af_json_array_at
        test    rax, rax
        js      .invalid
        mov     r15, [rsp]
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [tbl_k_model_alias]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        TBL_APPEND_TAB
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [tbl_k_policy]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        TBL_APPEND_TAB
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [tbl_k_targets]
        call    af_tbl_member_array_count
        test    rax, rax
        js      .done
        TBL_APPEND_TAB
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [tbl_k_enabled]
        call    af_tbl_member_bool
        test    rax, rax
        js      .done
        TBL_APPEND_TAB
        mov     rdi, r15
        lea     rsi, [tbl_k_fallback]
        lea     rdx, [rsp + 8]
        call    af_json_get_object
        test    rax, rax
        js      .fallback_dash
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        lea     rdx, [tbl_k_max_attempts]
        call    af_tbl_member_int
        jmp     .fallback_done
.fallback_dash:
        mov     rdi, rbx
        lea     rsi, [tbl_dash]
        mov     rdx, 1
        call    af_buf_append
.fallback_done:
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        inc     r14
        jmp     .row
.invalid:
        mov     rax, AF_E_INVALID
        jmp     .done
.ok:
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; mcp.list table.
; ---------------------------------------------------------------------------
af_tbl_build_mcp:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        TBL_APPEND_STATIC tbl_h_mcp, tbl_h_mcp_len
        mov     rdi, r12
        call    af_json_array_count
        mov     r13, rax
        xor     r14d, r14d
.row:
        cmp     r14, r13
        jae     .ok
        mov     rdi, r12
        mov     rsi, r14
        lea     rdx, [rsp]
        call    af_json_array_at
        test    rax, rax
        js      .invalid
        mov     r15, [rsp]
%macro MCP_STRING_COLUMN 1
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [%1]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        TBL_APPEND_TAB
%endmacro
        MCP_STRING_COLUMN tbl_k_state
        MCP_STRING_COLUMN tbl_k_id
        MCP_STRING_COLUMN tbl_k_display_name
        MCP_STRING_COLUMN tbl_k_transport
        MCP_STRING_COLUMN tbl_k_era
        MCP_STRING_COLUMN tbl_k_protocol_version
%unmacro MCP_STRING_COLUMN 1
%macro MCP_INT_COLUMN 1
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [%1]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_TAB
%endmacro
        MCP_INT_COLUMN tbl_k_tool_count
        MCP_INT_COLUMN tbl_k_resource_count
%unmacro MCP_INT_COLUMN 1
        mov     rdi, rbx
        mov     rsi, r15
        lea     rdx, [tbl_k_restarts]
        call    af_tbl_member_int
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        inc     r14
        jmp     .row
.invalid:
        mov     rax, AF_E_INVALID
        jmp     .done
.ok:
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; Error envelope table.
; ---------------------------------------------------------------------------
af_tbl_build_error:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        TBL_APPEND_STATIC tbl_h_error, tbl_h_error_len
        TBL_APPEND_STATIC tbl_false, 5
        TBL_APPEND_TAB
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_code]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        TBL_APPEND_TAB
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_message]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        TBL_APPEND_TAB
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [tbl_k_field]
        call    af_tbl_member_string
        test    rax, rax
        js      .done
        TBL_APPEND_LF
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_tbl_flush(af_buffer *out, i64 fd) -> af_status
; ---------------------------------------------------------------------------
af_tbl_flush:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        call    af_buf_data
        mov     r13, rax
        mov     rdi, rbx
        call    af_buf_len
        mov     rdx, rax
        mov     rdi, r12
        mov     rsi, r13
        call    af_write_all
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_table_response(const char *frame, u64 frame_len,
;                       const char *method, u64 method_len, i64 fd)
;   -> af_status
;
; All input spans are BORROWED.  The parser document and output buffer are
; owned locally and released before return.
; ---------------------------------------------------------------------------
        global af_ctl_table_response
af_ctl_table_response:
        AF_ENTER 176
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi                ; frame
        mov     r12, rsi                ; frame len
        mov     r13, rdx                ; method
        mov     r14, rcx                ; method len
        mov     [rsp + 144], r8          ; fd

        mov     [rsp + AF_JSONLIM_MAX_BYTES], r12
        mov     qword [rsp + AF_JSONLIM_MAX_DEPTH], AF_CTLC_JSON_DEPTH
        mov     qword [rsp + AF_JSONLIM_MAX_STRING], AF_CTL_FRAME_DEFAULT_MAX
        mov     qword [rsp + AF_JSONLIM_MAX_ELEMS], AF_CTLC_JSON_ELEMENTS
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        lea     rcx, [rsp + 32]
        call    af_json_parse
        test    rax, rax
        js      .done
        lea     rdi, [rsp + 32]
        call    af_json_doc_root
        mov     [rsp + 64], rax
        mov     rdi, rax
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .free_invalid

        mov     rdi, [rsp + 64]
        lea     rsi, [tbl_k_ok]
        lea     rdx, [rsp + 80]
        call    af_json_get_bool
        test    rax, rax
        js      .free_invalid

        lea     rdi, [rsp + 96]
        mov     rsi, AF_CTLC_TABLE_OUTPUT_MAX
        call    af_buf_init
        test    rax, rax
        js      .free_return

        cmp     qword [rsp + 80], 0
        je      .error
        mov     rdi, [rsp + 64]
        lea     rsi, [tbl_k_result]
        lea     rdx, [rsp + 72]
        call    af_json_member
        test    rax, rax
        js      .buffer_invalid
        mov     r15, [rsp + 72]

        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [tbl_m_system_version]
        call    af_tbl_method_eq
        test    rax, rax
        jnz     .version
        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [tbl_m_system_snapshot]
        call    af_tbl_method_eq
        test    rax, rax
        jnz     .snapshot
        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [tbl_m_providers_list]
        call    af_tbl_method_eq
        test    rax, rax
        jnz     .providers
        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [tbl_m_routes_list]
        call    af_tbl_method_eq
        test    rax, rax
        jnz     .routes
        mov     rdi, r13
        mov     rsi, r14
        lea     rdx, [tbl_m_mcp_list]
        call    af_tbl_method_eq
        test    rax, rax
        jnz     .mcp
        jmp     .generic

.version:
        mov     rdi, r15
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .generic
        lea     rdi, [rsp + 96]
        mov     rsi, r15
        call    af_tbl_build_version
        jmp     .built
.snapshot:
        mov     rdi, r15
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .generic
        lea     rdi, [rsp + 96]
        mov     rsi, r15
        call    af_tbl_build_snapshot
        jmp     .built
.providers:
        mov     rdi, r15
        call    af_json_type
        cmp     rax, AF_JSON_ARRAY
        jne     .generic
        lea     rdi, [rsp + 96]
        mov     rsi, r15
        call    af_tbl_build_providers
        jmp     .built
.routes:
        mov     rdi, r15
        call    af_json_type
        cmp     rax, AF_JSON_ARRAY
        jne     .generic
        lea     rdi, [rsp + 96]
        mov     rsi, r15
        call    af_tbl_build_routes
        jmp     .built
.mcp:
        mov     rdi, r15
        call    af_json_type
        cmp     rax, AF_JSON_ARRAY
        jne     .generic
        lea     rdi, [rsp + 96]
        mov     rsi, r15
        call    af_tbl_build_mcp
        jmp     .built

.error:
        mov     rdi, [rsp + 64]
        lea     rsi, [tbl_k_error]
        lea     rdx, [rsp + 72]
        call    af_json_get_object
        test    rax, rax
        js      .buffer_invalid
        lea     rdi, [rsp + 96]
        mov     rsi, [rsp + 72]
        call    af_tbl_build_error
.built:
        test    rax, rax
        js      .buffer_return
        lea     rdi, [rsp + 96]
        mov     rsi, [rsp + 144]
        call    af_tbl_flush
        jmp     .buffer_return

.generic:
        ; Release owned parse/render state first, then emit the exact envelope.
        lea     rdi, [rsp + 96]
        call    af_buf_free
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        mov     rdi, [rsp + 144]
        mov     rsi, rbx
        mov     rdx, r12
        call    af_write_all
        test    rax, rax
        js      .done
        mov     rdi, [rsp + 144]
        lea     rsi, [tbl_lf]
        mov     rdx, 1
        call    af_write_all
        AF_LEAVE

.buffer_invalid:
        mov     rax, AF_E_INVALID
.buffer_return:
        mov     [rsp + 152], rax
        lea     rdi, [rsp + 96]
        call    af_buf_free
        mov     rax, [rsp + 152]
.free_return:
        mov     [rsp + 152], rax
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        mov     rax, [rsp + 152]
.done:
        AF_LEAVE
.free_invalid:
        mov     rax, AF_E_INVALID
        jmp     .free_return
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
