; AsmFlow — asmflowd lifecycle orchestration.
;
; This module owns the startup order and the shutdown order, and is the only
; place that knows either. Startup acquires resources one at a time, each
; registering its teardown before the next begins, so a failure at step N unwinds
; exactly N-1 acquisitions. Shutdown runs that list backwards.
;
; Startup:
;   1. block signals and open the signal descriptor    [implemented]
;   2. resolve the configuration path                  [implemented]
;   3. load and validate the configuration             [implemented]
;   4. resolve secret references                       [implemented]
;   5. open storage, migrate, enable WAL               [implemented]
;   6. project the configuration into the database     [implemented]
;   7. bind the control socket                         [implemented]
;   8. bind the data-plane listener                    M5
;   9. start enabled MCP servers                       M8
;  10. enter the event loop                            [implemented]
;
; Shutdown (HARNESS.md M11 DoD 6): stop accepting, drain what is in flight, stop
; MCP children, close the database. The steps that do not exist yet are marked
; where they belong rather than left to be discovered later.

        bits 64
        default rel

%include "asmflow.inc"
%include "config.inc"
%include "control.inc"
%include "http.inc"
%include "db.inc"
%include "loop.inc"
%include "runtime.inc"
%include "provider.inc"
%include "routing.inc"
%include "mcp.inc"

        extern af_out_bytes
        extern af_out_cstr
        extern af_out_u64

        extern af_alloc
        extern af_free
        extern af_mem_zero
        extern af_arena_init
        extern af_arena_finalize
        extern af_buf_init
        extern af_buf_free
        extern af_buf_data
        extern af_buf_len

        extern af_config_read_file
        extern af_config_default_path
        extern af_config_parse
        extern af_config_release
        extern af_config_resolve_secrets

        extern af_cfg_err_init
        extern af_cfg_err_free
        extern af_cfg_err_code
        extern af_cfg_err_pointer
        extern af_cfg_err_pointer_len
        extern af_cfg_err_message
        extern af_cfg_err_message_len

        extern af_db_open
        extern af_db_close
        extern af_db_enable_wal
        extern af_migrations_apply
        extern af_repo_sync_config

        extern af_loop_init
        extern af_loop_close
        extern af_loop_add
        extern af_loop_run
        extern af_loop_stop

        extern af_ctl_server_init
        extern af_ctl_server_shutdown
        extern af_ctl_check_permissions

        extern af_http_server_init
        extern af_http_server_shutdown

        extern af_prov_engine_init
        extern af_prov_engine_shutdown

        extern af_routing_init
        extern af_routing_free

        extern af_mcp_sup_init
        extern af_mcp_sup_shutdown
        extern af_mcp_set_limits

        extern af_signal_mask_build
        extern af_signals_block
        extern af_signalfd_open
        extern af_signalfd_next
        extern af_signal_is_termination
        extern af_sys_close
        extern af_realtime_ms
        extern af_monotonic_ns

%define AF_FD_STDOUT 1
%define AF_FD_STDERR 2

        section .rodata

msg_cfg_ok_prefix: db "asmflowd: configuration accepted: "
msg_cfg_ok_prefix_len equ $ - msg_cfg_ok_prefix
msg_providers:  db " provider(s), "
msg_providers_len equ $ - msg_providers
msg_routes:     db " route(s), "
msg_routes_len equ $ - msg_routes
msg_servers:    db " MCP server(s)", 10
msg_servers_len equ $ - msg_servers

msg_cfg_rejected: db "asmflowd: configuration rejected", 10
msg_cfg_rejected_len equ $ - msg_cfg_rejected
msg_at:      db "  at: "
msg_at_len   equ $ - msg_at
msg_why:     db "  rule: "
msg_why_len  equ $ - msg_why
msg_code:    db "  code: "
msg_code_len equ $ - msg_code
msg_root:    db "(document root)"
msg_root_len equ $ - msg_root
msg_nl:      db 10

msg_read_failed: db "asmflowd: could not read the configuration file: "
msg_read_failed_len equ $ - msg_read_failed
msg_secret_hint:
        db      "  hint: the file is valid; a referenced environment variable is unset", 10
msg_secret_hint_len equ $ - msg_secret_hint

msg_storage_failed: db "asmflowd: storage could not be opened or migrated", 10
msg_storage_failed_len equ $ - msg_storage_failed
msg_control_failed: db "asmflowd: the control socket could not be bound", 10
msg_control_failed_len equ $ - msg_control_failed
msg_internal_failed: db "asmflowd: internal startup failure", 10
msg_internal_failed_len equ $ - msg_internal_failed

msg_listening: db "asmflowd: control socket ready at "
msg_listening_len equ $ - msg_listening
msg_http_ready: db "asmflowd: gateway listening on "
msg_http_ready_len equ $ - msg_http_ready
msg_colon: db ":"
msg_no_upstream:
        db      "asmflowd: the console is not wired in this build.", 10
msg_no_upstream_len equ $ - msg_no_upstream
msg_listener_failed: db "asmflowd: the gateway listener could not be bound", 10
msg_listener_failed_len equ $ - msg_listener_failed
msg_upstream_failed: db "asmflowd: the upstream client could not be started", 10
msg_upstream_failed_len equ $ - msg_upstream_failed
msg_shutdown: db "asmflowd: shutting down", 10
msg_shutdown_len equ $ - msg_shutdown

        section .text

; ---------------------------------------------------------------------------
; af_daemon_report_config_error(const af_cfg_error *err) -> void
;
; The rule that was broken, the JSON Pointer that names where, and the numeric
; code. Everything printed comes from the error object, which by construction
; holds no value from the file.
; ---------------------------------------------------------------------------
        global af_daemon_report_config_error
af_daemon_report_config_error:
        AF_ENTER 0
        mov     rbx, rdi

        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_cfg_rejected]
        mov     rdx, msg_cfg_rejected_len
        call    af_out_bytes

        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_at]
        mov     rdx, msg_at_len
        call    af_out_bytes
        mov     rdi, rbx
        call    af_cfg_err_pointer_len
        mov     r12, rax
        test    r12, r12
        jz      .root
        mov     rdi, rbx
        call    af_cfg_err_pointer
        mov     rsi, rax
        mov     rdx, r12
        mov     edi, AF_FD_STDERR
        call    af_out_bytes
        jmp     .after_location
.root:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_root]
        mov     rdx, msg_root_len
        call    af_out_bytes
.after_location:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_nl]
        mov     rdx, 1
        call    af_out_bytes

        mov     rdi, rbx
        call    af_cfg_err_message_len
        mov     r12, rax
        test    r12, r12
        jz      .after_message
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_why]
        mov     rdx, msg_why_len
        call    af_out_bytes
        mov     rdi, rbx
        call    af_cfg_err_message
        mov     rsi, rax
        mov     rdx, r12
        mov     edi, AF_FD_STDERR
        call    af_out_bytes
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_nl]
        mov     rdx, 1
        call    af_out_bytes
.after_message:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_code]
        mov     rdx, msg_code_len
        call    af_out_bytes
        mov     rdi, rbx
        call    af_cfg_err_code
        neg     rax
        mov     rsi, rax
        mov     edi, AF_FD_STDERR
        call    af_out_u64
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_nl]
        mov     rdx, 1
        call    af_out_bytes
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_daemon_load_config(af_runtime *rt, af_cfg_error *err) -> af_status
;
; Steps 2 to 4. Leaves a published snapshot in RT_CONFIG on success and touches
; nothing on failure, which is what makes this reusable as the reload path.
; ---------------------------------------------------------------------------
        global af_daemon_load_config
af_daemon_load_config:
        AF_ENTER 64
        mov     rbx, rdi                ; runtime
        mov     r12, rsi                ; error object
        mov     qword [rsp + 32], 0     ; candidate snapshot

        lea     rdi, [rsp]              ; af_buffer for the file
        mov     rsi, 1
        call    af_daemon_buffer_reset

        mov     r13, [rbx + RT_CONFIG_PATH]
        test    r13, r13
        jnz     .have_path
        mov     rdi, [rbx + RT_CONFIG_ARENA]
        lea     rsi, [rsp + 40]
        call    af_config_default_path
        test    rax, rax
        js      .done
        mov     r13, [rsp + 40]
        mov     [rbx + RT_CONFIG_PATH], r13
.have_path:

        mov     rdi, r13
        lea     rsi, [rsp]
        call    af_config_read_file
        test    rax, rax
        js      .read_failed

        lea     rdi, [rsp]
        call    af_buf_data
        mov     r14, rax
        lea     rdi, [rsp]
        call    af_buf_len
        mov     r15, rax

        mov     rdi, r14
        mov     rsi, r15
        mov     rdx, r12
        lea     rcx, [rsp + 32]
        call    af_config_parse
        test    rax, rax
        js      .free_buffer

        mov     rdi, [rsp + 32]
        mov     rsi, r12
        call    af_config_resolve_secrets
        test    rax, rax
        js      .release_candidate

        ; Publish atomically: the new snapshot replaces the old one in a single
        ; store, and the old reference is dropped only afterwards. A request
        ; holding the old one keeps it alive until it finishes.
        mov     rax, [rbx + RT_CONFIG]
        mov     rcx, [rsp + 32]
        mov     [rbx + RT_CONFIG], rcx
        mov     [rsp + 48], rax
        inc     qword [rbx + RT_RELOAD_COUNT]

        lea     rdi, [rsp]
        call    af_buf_free
        mov     rdi, [rsp + 48]
        call    af_config_release
        AF_LEAVE_OK

.release_candidate:
        mov     [rsp + 48], rax
        mov     rdi, [rsp + 32]
        call    af_config_release
        lea     rdi, [rsp]
        call    af_buf_free
        mov     rax, [rsp + 48]
        AF_LEAVE
.free_buffer:
        mov     [rsp + 48], rax
        lea     rdi, [rsp]
        call    af_buf_free
        mov     rax, [rsp + 48]
        AF_LEAVE
.read_failed:
        mov     [rsp + 48], rax
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_read_failed]
        mov     rdx, msg_read_failed_len
        call    af_out_bytes
        mov     edi, AF_FD_STDERR
        mov     rsi, r13
        call    af_out_cstr
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_nl]
        mov     rdx, 1
        call    af_out_bytes
        mov     rax, [rsp + 48]
        AF_LEAVE
.done:
        AF_LEAVE

; A buffer that af_config_read_file has not reached yet must still be safe to
; free on an early error path, so it starts from a known-clean state.
af_daemon_buffer_reset:
        mov     qword [rdi], 0
        mov     qword [rdi + 8], 0
        mov     qword [rdi + 16], 0
        mov     qword [rdi + 24], 1
        ret

; ---------------------------------------------------------------------------
; af_daemon_report_config_summary(af_config *cfg) -> void
;
; Counts, never contents.
; ---------------------------------------------------------------------------
af_daemon_report_config_summary:
        AF_ENTER 0
        mov     rbx, rdi
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_cfg_ok_prefix]
        mov     rdx, msg_cfg_ok_prefix_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, [rbx + CFG_PROVIDER_COUNT]
        call    af_out_u64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_providers]
        mov     rdx, msg_providers_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, [rbx + CFG_ROUTE_COUNT]
        call    af_out_u64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_routes]
        mov     rdx, msg_routes_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, [rbx + CFG_MCP_COUNT]
        call    af_out_u64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_servers]
        mov     rdx, msg_servers_len
        call    af_out_bytes
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_daemon_check_config(const char *config_path_or_null) -> int exit code
;
; Validates without binding a listener, opening the database, or spawning a
; child. AF_EXIT_OK or AF_EXIT_CONFIG.
; ---------------------------------------------------------------------------
        global af_daemon_check_config
af_daemon_check_config:
        AF_ENTER 256
        mov     rbx, rdi

        ; [rsp +   0] af_arena (48)
        ; [rsp +  48] af_cfg_error (72)
        ; [rsp + 128] af_runtime (96)
        lea     rdi, [rsp]
        mov     rsi, 4096
        mov     rdx, 65536
        call    af_arena_init
        test    rax, rax
        js      .internal

        lea     rdi, [rsp + 48]
        call    af_cfg_err_init
        test    rax, rax
        js      .free_arena

        lea     rdi, [rsp + 128]
        mov     rsi, RT_SIZE
        call    af_mem_zero
        mov     [rsp + 128 + RT_CONFIG_PATH], rbx
        lea     rax, [rsp]
        mov     [rsp + 128 + RT_CONFIG_ARENA], rax

        lea     rdi, [rsp + 128]
        lea     rsi, [rsp + 48]
        call    af_daemon_load_config
        test    rax, rax
        js      .rejected

        mov     rdi, [rsp + 128 + RT_CONFIG]
        call    af_daemon_report_config_summary
        mov     rdi, [rsp + 128 + RT_CONFIG]
        call    af_config_release
        mov     qword [rsp + 240], AF_EXIT_OK
        jmp     .cleanup

.rejected:
        cmp     rax, AF_E_CFG_SECRET_MISSING
        jne     .report
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_secret_hint]
        mov     rdx, msg_secret_hint_len
        call    af_out_bytes
.report:
        lea     rdi, [rsp + 48]
        call    af_cfg_err_code
        test    rax, rax
        jz      .no_detail
        lea     rdi, [rsp + 48]
        call    af_daemon_report_config_error
.no_detail:
        mov     qword [rsp + 240], AF_EXIT_CONFIG

.cleanup:
        lea     rdi, [rsp + 48]
        call    af_cfg_err_free
        lea     rdi, [rsp]
        call    af_arena_finalize
        mov     rax, [rsp + 240]
        AF_LEAVE
.free_arena:
        lea     rdi, [rsp]
        call    af_arena_finalize
.internal:
        mov     eax, AF_EXIT_INTERNAL
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_daemon_on_signal(void *ctx, i64 fd, u64 events) -> void
;
; Signals arrive here as ordinary loop events, so shutdown runs on the normal
; path with the whole runtime available rather than inside a handler that may
; call almost nothing.
; ---------------------------------------------------------------------------
        global af_daemon_on_signal
af_daemon_on_signal:
        AF_ENTER 32
        mov     rbx, rdi                ; runtime
        mov     r12, rsi                ; signal descriptor
.drain:
        mov     rdi, r12
        lea     rsi, [rsp]
        call    af_signalfd_next
        test    rax, rax
        js      .done                   ; AF_E_AGAIN: the queue is empty
        mov     rdi, [rsp]
        call    af_signal_is_termination
        test    rax, rax
        jz      .drain
        mov     qword [rbx + RT_SHUTTING_DOWN], 1
        mov     rdi, [rbx + RT_LOOP]
        call    af_loop_stop
        jmp     .drain
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; The daemon context.
;
; Every long-lived structure lives in one heap block rather than on the stack.
; The event loop's source table and the control server's connection table are
; several kilobytes each; putting them in a stack frame would silently write
; past it. One allocation also means the teardown path can run safely from the
; very first failure, because the whole block is zeroed before anything else
; happens.
; ---------------------------------------------------------------------------
%define CTX_RT     0
%define CTX_DB     (CTX_RT + RT_SIZE)
%define CTX_ARENA  (CTX_DB + DB_SIZE)
%define CTX_ERR    (CTX_ARENA + 48)
%define CTX_MASK   (CTX_ERR + CFGERR_SIZE)
%define CTX_SIGFD  (CTX_MASK + 8)
%define CTX_FLAGS  (CTX_SIGFD + 8)
%define CTX_EXIT   (CTX_FLAGS + 8)
%define CTX_LOOP   (((CTX_EXIT + 8) + 15) & ~15)
%define CTX_CTL    (CTX_LOOP + LOOP_SIZE)
%define CTX_HTTP   (CTX_CTL + CTLS_SIZE)
%define CTX_PROV   (CTX_HTTP + HS_SIZE)
%define CTX_ROUTING (CTX_PROV + PE_SIZE)
%define CTX_MCP    (CTX_ROUTING + RTB_SIZE)
%define CTX_SIZE   (CTX_MCP + MS_SIZE)

; Bits in CTX_FLAGS, so teardown knows what was actually acquired.
%define CTX_F_ARENA   1
%define CTX_F_ERR     2
%define CTX_F_DB      4
%define CTX_F_LOOP    8
%define CTX_F_CTL     16
%define CTX_F_HTTP    32
%define CTX_F_PROV    64
%define CTX_F_ROUTING 128
%define CTX_F_MCP     256

; ---------------------------------------------------------------------------
; af_daemon_run(const char *config_path_or_null) -> int exit code
;
; Ownership: `config_path_or_null` is BORROWED from argv.
; ---------------------------------------------------------------------------
        global af_daemon_run
af_daemon_run:
        AF_ENTER 32
        mov     r14, rdi                ; configuration path, or NULL

        mov     rdi, CTX_SIZE
        call    af_alloc
        test    rax, rax
        jz      .no_context
        mov     rbx, rax
        mov     rdi, rbx
        mov     rsi, CTX_SIZE
        call    af_mem_zero
        mov     qword [rbx + CTX_SIGFD], -1
        mov     qword [rbx + CTX_EXIT], AF_EXIT_OK

        ; --- 1. signals, before anything else can be interrupted ---
        lea     rdi, [rbx + CTX_MASK]
        call    af_signal_mask_build
        lea     rdi, [rbx + CTX_MASK]
        xor     esi, esi
        call    af_signals_block
        test    rax, rax
        js      .internal
        lea     rdi, [rbx + CTX_MASK]
        lea     rsi, [rbx + CTX_SIGFD]
        call    af_signalfd_open
        test    rax, rax
        js      .internal

        ; --- 2-4. configuration ---
        lea     rdi, [rbx + CTX_ARENA]
        mov     rsi, 4096
        mov     rdx, 65536
        call    af_arena_init
        test    rax, rax
        js      .internal
        or      qword [rbx + CTX_FLAGS], CTX_F_ARENA

        lea     rdi, [rbx + CTX_ERR]
        call    af_cfg_err_init
        test    rax, rax
        js      .internal
        or      qword [rbx + CTX_FLAGS], CTX_F_ERR

        mov     [rbx + CTX_RT + RT_CONFIG_PATH], r14
        lea     rax, [rbx + CTX_ARENA]
        mov     [rbx + CTX_RT + RT_CONFIG_ARENA], rax
        lea     rax, [rbx + CTX_DB]
        mov     [rbx + CTX_RT + RT_DB], rax
        lea     rax, [rbx + CTX_LOOP]
        mov     [rbx + CTX_RT + RT_LOOP], rax
        lea     rdi, [rbx + CTX_RT + RT_STARTED_MS]
        call    af_realtime_ms
        lea     rdi, [rbx + CTX_RT + RT_STARTED_NS]
        call    af_monotonic_ns

        lea     rdi, [rbx + CTX_RT]
        lea     rsi, [rbx + CTX_ERR]
        call    af_daemon_load_config
        test    rax, rax
        js      .config_rejected
        mov     r13, [rbx + CTX_RT + RT_CONFIG]

        ; --- 5. storage ---
        lea     rdi, [rbx + CTX_DB]
        mov     rsi, [r13 + CFG_STO_DB_PATH]
        mov     rdx, [r13 + CFG_STO_BUSY_MS]
        call    af_db_open
        test    rax, rax
        js      .storage_failed
        or      qword [rbx + CTX_FLAGS], CTX_F_DB
        lea     rdi, [rbx + CTX_DB]
        call    af_migrations_apply
        test    rax, rax
        js      .storage_failed
        lea     rdi, [rbx + CTX_DB]
        call    af_db_enable_wal
        test    rax, rax
        js      .storage_failed

        ; --- 6. project the configuration into the database ---
        lea     rdi, [rbx + CTX_DB]
        mov     rsi, r13
        call    af_repo_sync_config
        test    rax, rax
        js      .storage_failed

        ; --- 7. event loop and control socket ---
        lea     rdi, [rbx + CTX_LOOP]
        call    af_loop_init
        test    rax, rax
        js      .internal
        or      qword [rbx + CTX_FLAGS], CTX_F_LOOP

        lea     rdi, [rbx + CTX_LOOP]
        mov     rsi, [rbx + CTX_SIGFD]
        mov     rdx, EPOLLIN
        lea     rcx, [af_daemon_on_signal]
        lea     r8, [rbx + CTX_RT]
        call    af_loop_add
        test    rax, rax
        js      .internal

        lea     rax, [rbx + CTX_CTL]
        mov     [rbx + CTX_RT + RT_CTL], rax
        mov     rdi, rax
        mov     rsi, [r13 + CFG_CTL_SOCKET_PATH]
        mov     rdx, [r13 + CFG_CTL_FRAME_MAX]
        lea     rcx, [rbx + CTX_LOOP]
        lea     r8, [rbx + CTX_RT]
        call    af_ctl_server_init
        test    rax, rax
        js      .control_failed
        or      qword [rbx + CTX_FLAGS], CTX_F_CTL

        ; Assert the permission contract after binding rather than trusting the
        ; bind: HARNESS.md M4 DoD 5 is a property of what is on disk.
        mov     rdi, [r13 + CFG_CTL_SOCKET_PATH]
        call    af_ctl_check_permissions
        test    rax, rax
        js      .control_failed

        ; --- 8. routing state ---
        ;
        ; Health, circuits, and round-robin cursors. Kept apart from the
        ; configuration snapshot because it has to survive a reload: a circuit
        ; that opened because a provider is down must stay open across the
        ; reload that happens while it is down.
        lea     rdi, [rbx + CTX_ROUTING]
        call    af_routing_init
        test    rax, rax
        js      .internal
        or      qword [rbx + CTX_FLAGS], CTX_F_ROUTING
        lea     rax, [rbx + CTX_ROUTING]
        mov     [rbx + CTX_RT + RT_ROUTING], rax

        ; --- 9. the upstream client ---
        ;
        ; Before the listener, deliberately. Everything that can fail about
        ; libcurl — a version whose enumerators do not match ours, a timer
        ; descriptor the kernel will not give — fails here, where the daemon can
        ; still decline to start, rather than on the first request that arrives
        ; at a listener already accepting traffic.
        lea     rdi, [rbx + CTX_PROV]
        lea     rsi, [rbx + CTX_LOOP]
        lea     rdx, [rbx + CTX_RT]
        call    af_prov_engine_init
        test    rax, rax
        js      .upstream_failed
        or      qword [rbx + CTX_FLAGS], CTX_F_PROV
        lea     rax, [rbx + CTX_PROV]
        mov     [rbx + CTX_RT + RT_PROV], rax

        ; --- 10. the MCP supervisor ---
        ;
        ; Nothing is spawned here. A configuration naming a command that does
        ; not exist should produce a server in `failed` with a diagnosable
        ; reason, not a daemon that refuses to start — the gateway's other
        ; duties are unaffected by an MCP server being unavailable.
        lea     rdi, [rbx + CTX_MCP]
        lea     rsi, [rbx + CTX_LOOP]
        lea     rdx, [rbx + CTX_RT]
        call    af_mcp_sup_init
        test    rax, rax
        js      .internal
        or      qword [rbx + CTX_FLAGS], CTX_F_MCP
        lea     rax, [rbx + CTX_MCP]
        mov     [rbx + CTX_RT + RT_MCP], rax
        lea     rdi, [rbx + CTX_MCP]
        call    af_mcp_set_limits

        ; --- 11. the data-plane listener ---
        lea     rdi, [rbx + CTX_HTTP]
        mov     rsi, r13
        lea     rdx, [rbx + CTX_LOOP]
        lea     rcx, [rbx + CTX_RT]
        call    af_http_server_init
        test    rax, rax
        js      .listener_failed
        or      qword [rbx + CTX_FLAGS], CTX_F_HTTP

        mov     qword [rbx + CTX_RT + RT_READY], 1
        mov     rdi, r13
        call    af_daemon_report_config_summary
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_listening]
        mov     rdx, msg_listening_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, [r13 + CFG_CTL_SOCKET_PATH]
        call    af_out_cstr
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_nl]
        mov     rdx, 1
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_http_ready]
        mov     rdx, msg_http_ready_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, [r13 + CFG_LST_HOST]
        call    af_out_cstr
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_colon]
        mov     rdx, 1
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, [r13 + CFG_LST_PORT]
        call    af_out_u64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [msg_nl]
        mov     rdx, 1
        call    af_out_bytes
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_no_upstream]
        mov     rdx, msg_no_upstream_len
        call    af_out_bytes

        ; --- 10. serve ---
        lea     rdi, [rbx + CTX_LOOP]
        mov     rsi, 1000               ; wake at least once a second for timers
        call    af_loop_run
        jmp     .shutdown

.config_rejected:
        cmp     rax, AF_E_CFG_SECRET_MISSING
        jne     .report_config
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_secret_hint]
        mov     rdx, msg_secret_hint_len
        call    af_out_bytes
.report_config:
        lea     rdi, [rbx + CTX_ERR]
        call    af_cfg_err_code
        test    rax, rax
        jz      .config_no_detail
        lea     rdi, [rbx + CTX_ERR]
        call    af_daemon_report_config_error
.config_no_detail:
        mov     qword [rbx + CTX_EXIT], AF_EXIT_CONFIG
        jmp     .shutdown

.storage_failed:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_storage_failed]
        mov     rdx, msg_storage_failed_len
        call    af_out_bytes
        mov     qword [rbx + CTX_EXIT], AF_EXIT_STORAGE
        jmp     .shutdown

.upstream_failed:
        mov     [rbx + CTX_EXIT], rax
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_upstream_failed]
        mov     rdx, msg_upstream_failed_len
        call    af_out_bytes
        mov     qword [rbx + CTX_EXIT], AF_EXIT_CONFIG
        jmp     .shutdown

.listener_failed:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_listener_failed]
        mov     rdx, msg_listener_failed_len
        call    af_out_bytes
        mov     qword [rbx + CTX_EXIT], AF_EXIT_LISTENER
        jmp     .shutdown

.control_failed:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_control_failed]
        mov     rdx, msg_control_failed_len
        call    af_out_bytes
        mov     qword [rbx + CTX_EXIT], AF_EXIT_LISTENER
        jmp     .shutdown

.internal:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_internal_failed]
        mov     rdx, msg_internal_failed_len
        call    af_out_bytes
        mov     qword [rbx + CTX_EXIT], AF_EXIT_INTERNAL

; Shutdown unwinds the acquisitions in reverse. Each step runs only if its flag
; says it happened, so this is also the failure path from any point above.
.shutdown:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_shutdown]
        mov     rdx, msg_shutdown_len
        call    af_out_bytes

        ; Stop accepting first, so no new work arrives while the rest unwinds.
        ; The data plane goes before the control socket, so an operator watching
        ; through the console sees the gateway stop rather than losing the
        ; connection they were watching it through.
        test    qword [rbx + CTX_FLAGS], CTX_F_HTTP
        jz      .no_http
        lea     rdi, [rbx + CTX_HTTP]
        call    af_http_server_shutdown
.no_http:
        ; MCP owns a separate curl multi handle in M9. Stop every MCP transfer
        ; and stdio process before the provider releases process-wide libcurl.
        test    qword [rbx + CTX_FLAGS], CTX_F_MCP
        jz      .no_mcp
        mov     qword [rbx + CTX_RT + RT_MCP], 0
        lea     rdi, [rbx + CTX_MCP]
        call    af_mcp_sup_shutdown
.no_mcp:
        ; The provider engine owns curl_global_cleanup until that lifetime is
        ; moved to a common daemon wrapper, so it must be the last curl user.
        test    qword [rbx + CTX_FLAGS], CTX_F_PROV
        jz      .no_upstream
        mov     qword [rbx + CTX_RT + RT_PROV], 0
        lea     rdi, [rbx + CTX_PROV]
        call    af_prov_engine_shutdown
.no_upstream:
        ; After the engine, because abandoning an exchange releases a
        ; concurrency slot against the state this frees.
        test    qword [rbx + CTX_FLAGS], CTX_F_ROUTING
        jz      .no_routing
        mov     qword [rbx + CTX_RT + RT_ROUTING], 0
        lea     rdi, [rbx + CTX_ROUTING]
        call    af_routing_free
.no_routing:
        test    qword [rbx + CTX_FLAGS], CTX_F_CTL
        jz      .no_control
        lea     rdi, [rbx + CTX_CTL]
        call    af_ctl_server_shutdown
.no_control:
        ; M8 stops MCP children here.

        test    qword [rbx + CTX_FLAGS], CTX_F_LOOP
        jz      .no_loop
        lea     rdi, [rbx + CTX_LOOP]
        call    af_loop_close
.no_loop:
        mov     rdi, [rbx + CTX_SIGFD]
        cmp     rdi, 0
        jl      .no_signalfd
        call    af_sys_close
.no_signalfd:
        test    qword [rbx + CTX_FLAGS], CTX_F_DB
        jz      .no_db
        lea     rdi, [rbx + CTX_DB]
        call    af_db_close
.no_db:
        mov     rdi, [rbx + CTX_RT + RT_CONFIG]
        call    af_config_release
        test    qword [rbx + CTX_FLAGS], CTX_F_ERR
        jz      .no_err
        lea     rdi, [rbx + CTX_ERR]
        call    af_cfg_err_free
.no_err:
        test    qword [rbx + CTX_FLAGS], CTX_F_ARENA
        jz      .no_arena
        lea     rdi, [rbx + CTX_ARENA]
        call    af_arena_finalize
.no_arena:
        mov     r12, [rbx + CTX_EXIT]
        mov     rdi, rbx
        call    af_free
        mov     rax, r12
        AF_LEAVE

.no_context:
        mov     edi, AF_FD_STDERR
        lea     rsi, [msg_internal_failed]
        mov     rdx, msg_internal_failed_len
        call    af_out_bytes
        mov     eax, AF_EXIT_INTERNAL
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_daemon_context_size() -> u64
;
; Exposed so a test can assert the block is big enough for the structures it
; contains, rather than discovering an overflow as memory corruption.
; ---------------------------------------------------------------------------
        global af_daemon_context_size
af_daemon_context_size:
        mov     rax, CTX_SIZE
        ret

        global af_daemon_context_loop_offset
af_daemon_context_loop_offset:
        mov     rax, CTX_LOOP
        ret

        global af_daemon_context_ctl_offset
af_daemon_context_ctl_offset:
        mov     rax, CTX_CTL
        ret

        global af_daemon_context_http_offset
af_daemon_context_http_offset:
        mov     rax, CTX_HTTP
        ret
