; AsmFlow — supervising MCP stdio servers.
;
; The state machine is docs/MCP_COMPATIBILITY.md 10:
;
;   stopped -> starting -> probing -> ready
;                       \-> degraded
;                       \-> failed -> restarting -> starting
;                                  \-> crash_loop
;
; Everything below either moves a child along that machine or accounts for what
; it did. Three of the rules are worth stating before the code.
;
; Era is decided once per process lifetime and re-probed after every restart
; (M8 DoD 5). A restarted server may be a different build; caching the era
; across the restart would mean speaking the previous process's protocol to the
; new one, and the failure would look like a server bug.
;
; The restart budget is a sliding window with a bounded backoff, and once it is
; spent the child stays in `crash_loop` until an operator resets it (M8 DoD 9).
; A supervisor that kept retrying would turn one broken server into a fork bomb
; that also fills the disk with its own logs.
;
; A child is reaped on every path that ends it (M8 DoD 8). A process nobody
; waits for is a zombie whether it exited, was asked to stop, or was killed —
; and a supervisor that leaks them exhausts the process table of the machine it
; was supposed to be looking after.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "fileio.inc"
%include "loop.inc"
%include "socket.inc"
%include "runtime.inc"
%include "config.inc"
%include "provider.inc"
%include "mcp.inc"

        extern af_mem_zero
        extern af_mem_copy
        extern af_cstr_eq
        extern af_cstr_len
        extern af_monotonic_now
        extern af_add_size
        extern af_mul_size

        extern af_buf_init
        extern af_buf_free
        extern af_buf_clear
        extern af_buf_len

        extern af_loop_add
        extern af_loop_del

        extern af_sys_timerfd_create
        extern af_sys_timerfd_settime
        extern af_sys_close
        extern af_sys_read
        extern af_sys_kill
        extern af_status_from_errno
        extern af_sys_nanosleep
        extern af_alloc
        extern af_free

        extern af_mcp_spawn
        extern af_mcp_reap
        extern af_mcp_signal
        extern af_mcp_close_pipes
        extern af_mcp_close_stdin
        extern af_mcp_read_stdout
        extern af_mcp_read_stderr
        extern af_mcp_write_stdin
        extern af_mcp_flush_errline
        extern af_mcp_request
        extern af_mcp_notify
        extern af_mcp_call_find
        extern af_mcp_call_release
        extern af_mcp_calls_release
        extern af_mcp_sweep_calls
        extern af_mcp_advance
        extern af_mcp_begin_inventory
        extern af_mcp_http_engine_init
        extern af_mcp_http_engine_shutdown
        extern af_mcp_http_start
        extern af_mcp_http_stop

        section .rodata

; The modern probe. `server/discover` is both the discovery call and the
; recommended stdio era probe (docs/MCP_COMPATIBILITY.md 3), so one round trip
; answers "which era is this" and "what can it do".
m_discover: db "server/discover", 0
p_discover:
        db '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",'
        db '"io.modelcontextprotocol/clientInfo":{"name":"AsmFlow","version":"'
        db AF_VERSION_STRING
        db '"},"io.modelcontextprotocol/clientCapabilities":{}}}', 0

m_initialize: db "initialize", 0
p_initialize:
        db '{"protocolVersion":"2025-11-25","clientInfo":{"name":"AsmFlow",'
        db '"version":"'
        db AF_VERSION_STRING
        db '"},"capabilities":{}}', 0
m_initialized: db "notifications/initialized", 0

m_tools:     db "tools/list", 0
m_resources: db "resources/list", 0
m_prompts:   db "prompts/list", 0

n_stopped:    db "stopped", 0
n_starting:   db "starting", 0
n_probing:    db "probing", 0
n_ready:      db "ready", 0
n_degraded:   db "degraded", 0
n_failed:     db "failed", 0
n_restarting: db "restarting", 0
n_crash_loop: db "crash_loop", 0
n_disabled:   db "disabled", 0
n_unknown:    db "unknown", 0

        section .data.rel.ro progbits align=8

state_names:
        dq n_stopped
        dq n_starting
        dq n_probing
        dq n_ready
        dq n_degraded
        dq n_failed
        dq n_restarting
        dq n_crash_loop
        dq n_disabled

        section .text

; ---------------------------------------------------------------------------
; af_mcp_own_cstr(const char *value) -> char *
;
; MCP-local owned duplication. Runtime MCP state may outlive the configuration
; snapshot (MC_ID) and negotiated state is process-owned (MC_VERSION), so this
; module must not reach into routing merely to borrow its private copy helper.
; ---------------------------------------------------------------------------
        global af_mcp_own_cstr
af_mcp_own_cstr:
        AF_ENTER 32
        test    rdi, rdi
        jz      .none
        mov     rbx, rdi
        call    af_cstr_len
        mov     r12, rax
        mov     rdi, r12
        mov     rsi, 1
        lea     rdx, [rsp]
        call    af_add_size
        test    rax, rax
        js      .none
        mov     rdi, [rsp]
        call    af_alloc
        test    rax, rax
        jz      .none
        mov     r13, rax
        mov     rdi, r13
        mov     rsi, rbx
        mov     rdx, [rsp]
        call    af_mem_copy
        mov     rax, r13
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_state_name(i64 state) -> const char *
; ---------------------------------------------------------------------------
        global af_mcp_state_name
af_mcp_state_name:
        cmp     rdi, AF_MCP_S_COUNT
        jae     .unknown
        lea     rax, [state_names]
        mov     rax, [rax + rdi*8]
        ret
.unknown:
        lea     rax, [n_unknown]
        ret

; ---------------------------------------------------------------------------
; af_mcp_sup_init(af_mcp_supervisor *sup, af_loop *loop, af_runtime *rt)
;   -> af_status
;
; Builds the child table from the configuration and arms the sweep. Nothing is
; spawned here: starting a server is the supervisor's own step, so a
; configuration that names an unreachable command does not stop the daemon.
; ---------------------------------------------------------------------------
        global af_mcp_sup_init
af_mcp_sup_init:
        AF_ENTER 96
;   [rsp +  0]  loop   [rsp + 16]  config   [rsp + 24]  index
;   [rsp +  8]  rt     [rsp + 32]  itimerspec (32 bytes)
%define SI_ITS 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx

        mov     rdi, rbx
        mov     rsi, MS_SIZE
        call    af_mem_zero
        mov     qword [rbx + MS_TIMER_FD], -1
        mov     rax, [rsp]
        mov     [rbx + MS_LOOP], rax
        mov     rax, [rsp + 8]
        mov     [rbx + MS_RT], rax

        xor     rcx, rcx
        test    rax, rax
        jz      .no_config
        mov     rcx, [rax + RT_CONFIG]
.no_config:
        mov     [rsp + 16], rcx
        test    rcx, rcx
        jz      .timer

        mov     qword [rsp + 24], 0
.each:
        mov     rax, [rsp + 16]
        mov     rcx, [rsp + 24]
        cmp     rcx, [rax + CFG_MCP_COUNT]
        jae     .timer
        mov     rdx, rcx
        imul    rdx, rdx, MCP_SIZE
        add     rdx, [rax + CFG_MCP_SERVERS]
        inc     qword [rsp + 24]

        ; Every validated MCP server has one transport-neutral runtime slot.
        ; The start/stop dispatch below keeps stdio process state and HTTP
        ; adapter state separate while control/readiness use the same id.
        cmp     qword [rdx + MCP_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .slot
        cmp     qword [rbx + MS_HTTP + HE_STARTED], 0
        jne     .slot
        mov     [rsp + 40], rdx
        lea     rdi, [rbx + MS_HTTP]
        mov     rsi, [rsp]
        mov     rdx, rbx
        call    af_mcp_http_engine_init
        test    rax, rax
        js      .fail
        mov     rdx, [rsp + 40]

.slot:

        mov     rcx, [rbx + MS_COUNT]
        cmp     rcx, AF_MCP_MAX_CHILDREN
        jae     .too_many
        mov     rax, rcx
        imul    rax, rax, MC_SIZE
        add     rax, rbx
        add     rax, MS_CHILDREN
        mov     r12, rax
        mov     r13, rdx
        mov     rdi, r12
        mov     rsi, r13
        call    af_mcp_child_init
        test    rax, rax
        js      .fail
        mov     [r12 + MC_SUP], rbx
        inc     qword [rbx + MS_COUNT]
        jmp     .each

.too_many:
        ; The schema and table currently have the same ceiling.  Keep this
        ; guard explicit so a future schema increase fails loudly rather than
        ; reintroducing silent truncation.
        mov     rax, AF_E_LIMIT
        jmp     .fail

.timer:
        ; One timer for the whole table, for the same reason the HTTP idle
        ; sweep uses one (ADR 0010): restarts and call deadlines are properties
        ; of the set, and a timer per child would double the descriptor cost of
        ; supervising one.
        mov     rdi, CLOCK_MONOTONIC
        mov     rsi, TFD_NONBLOCK | TFD_CLOEXEC
        call    af_sys_timerfd_create
        test    rax, rax
        js      .syscall_failed
        mov     [rbx + MS_TIMER_FD], rax

        lea     rdi, [rsp + SI_ITS]
        mov     rsi, ITS_SIZE
        call    af_mem_zero
        mov     qword [rsp + SI_ITS + ITS_INTERVAL_NSEC], AF_MCP_TICK_MS * NS_PER_MS
        mov     qword [rsp + SI_ITS + ITS_VALUE_NSEC], AF_MCP_TICK_MS * NS_PER_MS
        mov     rdi, [rbx + MS_TIMER_FD]
        xor     esi, esi
        lea     rdx, [rsp + SI_ITS]
        xor     ecx, ecx
        call    af_sys_timerfd_settime
        test    rax, rax
        js      .syscall_failed

        mov     rdi, [rbx + MS_LOOP]
        mov     rsi, [rbx + MS_TIMER_FD]
        mov     rdx, EPOLLIN
        lea     rcx, [af_mcp_on_tick]
        mov     r8, rbx
        call    af_loop_add
        test    rax, rax
        js      .fail
        mov     qword [rbx + MS_STARTED], 1
        AF_LEAVE_OK

.syscall_failed:
        mov     rdi, rax
        call    af_status_from_errno
.fail:
        mov     [rsp + 24], rax
        mov     rdi, rbx
        call    af_mcp_sup_shutdown
        mov     rax, [rsp + 24]
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_sup_shutdown(af_mcp_supervisor *sup) -> void
;
; The daemon is stopping. Every child is asked to stop, given a moment, and
; then insisted upon; every one is reaped before this returns.
;
; The wait is bounded and the escalation is unconditional. A supervisor that
; waited indefinitely for a server that had stopped reading would hang the
; daemon's own shutdown, and one that killed immediately would deny a server
; the chance to flush whatever it was in the middle of.
; ---------------------------------------------------------------------------
        global af_mcp_sup_shutdown
af_mcp_sup_shutdown:
        AF_ENTER 64
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi

        ; Ask.
        xor     r12, r12
.ask:
        cmp     r12, [rbx + MS_COUNT]
        jae     .wait
        mov     r13, r12
        imul    r13, r13, MC_SIZE
        add     r13, rbx
        add     r13, MS_CHILDREN
        mov     rdi, r13
        mov     rsi, rbx
        mov     rdx, 1
        call    af_mcp_stop
        inc     r12
        jmp     .ask

.wait:
        ; Collect whatever has already gone, then escalate to whatever has not.
        ; Bounded by attempts rather than by a clock, because this runs while
        ; the loop is stopping and there is nothing left to drive a timer.
        ; The longest validated configured grace is ten minutes.  Add the
        ; post-SIGTERM wait and two seconds for SIGKILL/reap while retaining a
        ; finite daemon-shutdown bound.
        mov     r14, (AF_MCP_SHUTDOWN_GRACE_MAX_MS + AF_MCP_TERM_WAIT_MS + 2000) / AF_MCP_SHUTDOWN_POLL_MS
.sweep:
        call    af_monotonic_now
        mov     [rsp], rax
        xor     r12, r12
        xor     r15, r15                        ; still running
.each:
        cmp     r12, [rbx + MS_COUNT]
        jae     .swept
        mov     r13, r12
        imul    r13, r13, MC_SIZE
        add     r13, rbx
        add     r13, MS_CHILDREN
        cmp     qword [r13 + MC_PID], 0
        jle     .next
        mov     rdi, r13
        call    af_mcp_reap
        cmp     rax, 1
        je      .reaped
        inc     r15
        mov     rdi, r13
        mov     rsi, [rsp]
        call    af_mcp_advance_shutdown
        jmp     .next
.reaped:
        mov     rdi, r13
        mov     rsi, rbx
        call    af_mcp_teardown
.next:
        inc     r12
        jmp     .each
.swept:
        test    r15, r15
        jz      .all_gone
        dec     r14
        test    r14, r14
        jz      .all_gone
        mov     rdi, rbx
        call    af_mcp_pause
        jmp     .sweep

.all_gone:
        xor     r12, r12
.release:
        cmp     r12, [rbx + MS_COUNT]
        jae     .timer
        mov     r13, r12
        imul    r13, r13, MC_SIZE
        add     r13, rbx
        add     r13, MS_CHILDREN
        mov     rdi, r13
        mov     rsi, rbx
        call    af_mcp_teardown
        mov     rdi, r13
        call    af_mcp_child_free
        inc     r12
        jmp     .release

.timer:
        lea     rdi, [rbx + MS_HTTP]
        call    af_mcp_http_engine_shutdown
        cmp     qword [rbx + MS_TIMER_FD], 0
        jl      .done
        mov     rdi, [rbx + MS_LOOP]
        test    rdi, rdi
        jz      .close_timer
        mov     rsi, [rbx + MS_TIMER_FD]
        call    af_loop_del
.close_timer:
        mov     rdi, [rbx + MS_TIMER_FD]
        call    af_sys_close
        mov     qword [rbx + MS_TIMER_FD], -1
        mov     qword [rbx + MS_STARTED], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_pause(af_mcp_supervisor *sup) -> void
;
; Ten milliseconds, for the shutdown loop above. The only sleep in the daemon,
; and it exists because shutdown runs after the loop has stopped: there is no
; timer left to wait on and nothing else for this process to be doing.
; ---------------------------------------------------------------------------
        global af_mcp_pause
af_mcp_pause:
        AF_ENTER 32
        mov     qword [rsp], 0
        mov     qword [rsp + 8], AF_MCP_SHUTDOWN_POLL_MS * NS_PER_MS
        lea     rdi, [rsp]
        xor     esi, esi
        call    af_sys_nanosleep
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_arm_shutdown_grace(af_mcp_child *child) -> void
;
; Starts the configured stdin-EOF grace.  The configuration validator bounds
; the millisecond value, so conversion to nanoseconds cannot overflow.
; ---------------------------------------------------------------------------
af_mcp_arm_shutdown_grace:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        call    af_monotonic_now
        mov     rcx, [rbx + MC_CFG]
        test    rcx, rcx
        jz      .armed
        mov     rcx, [rcx + MCP_SHUTDOWN_GRACE]
        imul    rcx, rcx, NS_PER_MS
        add     rax, rcx
.armed:
        mov     [rbx + MC_NEXT_START], rax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_advance_shutdown(af_mcp_child *child, u64 now_ns) -> void
;
; Deadline one sends SIGTERM after the configured stdin grace. Deadline two
; sends SIGKILL after a bounded post-TERM wait. Reaping remains the caller's
; responsibility so both the live loop and synchronous daemon shutdown use the
; same phase transition.
; ---------------------------------------------------------------------------
af_mcp_advance_shutdown:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        test    qword [rbx + MC_FLAGS], AF_MC_F_STOPPING
        jz      .done
        cmp     qword [rbx + MC_PID], 0
        jle     .done
        mov     rax, [rbx + MC_NEXT_START]
        test    rax, rax
        jz      .done
        cmp     r12, rax
        jb      .done
        test    qword [rbx + MC_FLAGS], AF_MC_F_TERM_SENT
        jnz     .kill

        mov     rdi, rbx
        mov     rsi, SIGTERM
        call    af_mcp_signal
        or      qword [rbx + MC_FLAGS], AF_MC_F_TERM_SENT
        lea     rax, [r12 + AF_MCP_TERM_WAIT_MS * NS_PER_MS]
        mov     [rbx + MC_NEXT_START], rax
        jmp     .done
.kill:
        mov     rdi, rbx
        mov     rsi, SIGKILL
        call    af_mcp_signal
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_child_free(af_mcp_child *child) -> void
; ---------------------------------------------------------------------------
        global af_mcp_child_free
af_mcp_child_free:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, rbx
        call    af_mcp_invalidate_process_view
        lea     rdi, [rbx + MC_INBOX]
        call    af_buf_free
        lea     rdi, [rbx + MC_OUTBOX]
        call    af_buf_free
        lea     rdi, [rbx + MC_ERRLINE]
        call    af_buf_free
        lea     rdi, [rbx + MC_ERRLOG]
        call    af_buf_free
        lea     rdi, [rbx + MC_TOOLS]
        call    af_buf_free
        lea     rdi, [rbx + MC_RESOURCES]
        call    af_buf_free
        lea     rdi, [rbx + MC_PROMPTS]
        call    af_buf_free
        mov     rdi, [rbx + MC_ID]
        test    rdi, rdi
        jz      .no_id
        call    af_free
        mov     qword [rbx + MC_ID], 0
.no_id:
        mov     rdi, [rbx + MC_VERSION]
        test    rdi, rdi
        jz      .done
        call    af_free
        mov     qword [rbx + MC_VERSION], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_child_init(af_mcp_child *child, af_cfg_mcp *cfg) -> af_status
; ---------------------------------------------------------------------------
        global af_mcp_child_init
af_mcp_child_init:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi

        mov     rdi, rbx
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     [rbx + MC_CFG], r12
        mov     rax, [r12 + MCP_TRANSPORT]
        mov     [rbx + MC_TRANSPORT], rax
        mov     qword [rbx + MC_STDIN_FD], -1
        mov     qword [rbx + MC_STDOUT_FD], -1
        mov     qword [rbx + MC_STDERR_FD], -1
        mov     qword [rbx + MC_ERA], AF_ERA_UNKNOWN

        ; The identifier is owned so a reload cannot free the key a running
        ; child is filed under.
        mov     rdi, [r12 + MCP_ID]
        call    af_mcp_own_cstr
        test    rax, rax
        jz      .nomem
        mov     [rbx + MC_ID], rax

        lea     rdi, [rbx + MC_INBOX]
        mov     rsi, AF_MCP_INBOX_MAX
        call    af_buf_init
        test    rax, rax
        js      .init_failed
        lea     rdi, [rbx + MC_OUTBOX]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        test    rax, rax
        js      .init_failed
        lea     rdi, [rbx + MC_ERRLINE]
        mov     rsi, AF_MCP_STDERR_LINE_HARD_MAX
        call    af_buf_init
        test    rax, rax
        js      .init_failed
        lea     rdi, [rbx + MC_ERRLOG]
        mov     rsi, AF_MCP_STDERR_KEEP * 2
        call    af_buf_init
        test    rax, rax
        js      .init_failed
        lea     rdi, [rbx + MC_TOOLS]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        test    rax, rax
        js      .init_failed
        lea     rdi, [rbx + MC_RESOURCES]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        test    rax, rax
        js      .init_failed
        lea     rdi, [rbx + MC_PROMPTS]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        test    rax, rax
        js      .init_failed

        mov     qword [rbx + MC_FRAME_MAX], 4194304
        mov     qword [rbx + MC_STDERR_MAX], 65536
        mov     qword [rbx + MC_BACKOFF_MS], 0

        cmp     qword [r12 + MCP_ENABLED], 0
        jne     .enabled
        mov     qword [rbx + MC_STATE], AF_MCP_S_DISABLED
        AF_LEAVE_OK
.enabled:
        mov     qword [rbx + MC_STATE], AF_MCP_S_STOPPED
        AF_LEAVE_OK
.nomem:
        mov     rax, AF_E_NOMEM
.init_failed:
        ; The record was zeroed before the first acquisition, so child_free is
        ; valid at every partial-initialisation point.  Preserve the original
        ; error while releasing every buffer and owned identifier acquired so
        ; far.
        mov     [rsp], rax
        mov     rdi, rbx
        call    af_mcp_child_free
        mov     rax, [rsp]
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_set_limits(af_mcp_supervisor *sup) -> void
;
; Copies the two framing ceilings onto every child. Called once the snapshot is
; known; a child reads its pipes under the numbers it was started with, so a
; reload cannot change a limit halfway through a message.
; ---------------------------------------------------------------------------
        global af_mcp_set_limits
af_mcp_set_limits:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rax, [rbx + MS_RT]
        test    rax, rax
        jz      .done
        mov     rax, [rax + RT_CONFIG]
        test    rax, rax
        jz      .done
        mov     r12, [rax + CFG_LIM_MCP_FRAME_MAX]
        mov     r13, [rax + CFG_LIM_STDERR_LINE_MAX]
        xor     rcx, rcx
.loop:
        cmp     rcx, [rbx + MS_COUNT]
        jae     .done
        mov     rax, rcx
        imul    rax, rax, MC_SIZE
        add     rax, rbx
        add     rax, MS_CHILDREN
        test    r12, r12
        jz      .no_frame
        mov     [rax + MC_FRAME_MAX], r12
.no_frame:
        test    r13, r13
        jz      .no_stderr
        mov     [rax + MC_STDERR_MAX], r13
.no_stderr:
        inc     rcx
        jmp     .loop
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_child_at(af_mcp_supervisor *sup, u64 index) -> af_mcp_child *
; af_mcp_child_for(af_mcp_supervisor *sup, const char *id) -> af_mcp_child *
; ---------------------------------------------------------------------------
        global af_mcp_child_at
af_mcp_child_at:
        test    rdi, rdi
        jz      .none
        cmp     rsi, [rdi + MS_COUNT]
        jae     .none
        mov     rax, rsi
        imul    rax, rax, MC_SIZE
        add     rax, rdi
        add     rax, MS_CHILDREN
        ret
.none:
        xor     eax, eax
        ret

        global af_mcp_child_for
af_mcp_child_for:
        AF_ENTER 32
        test    rdi, rdi
        jz      .none
        test    rsi, rsi
        jz      .none
        mov     rbx, rdi
        mov     r12, rsi
        xor     r13, r13
.scan:
        cmp     r13, [rbx + MS_COUNT]
        jae     .none
        mov     r14, r13
        imul    r14, r14, MC_SIZE
        add     r14, rbx
        add     r14, MS_CHILDREN
        mov     rdi, [r14 + MC_ID]
        test    rdi, rdi
        jz      .next
        mov     rsi, r12
        call    af_cstr_eq
        test    rax, rax
        jnz     .found
.next:
        inc     r13
        jmp     .scan
.found:
        mov     rax, r14
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_required_ready(af_mcp_supervisor *sup) -> i64
;
; Readiness is configuration policy, not just a count of running children.
; Optional servers never affect it.  Every enabled required stdio entry must
; have a live READY child; an enabled required Streamable-HTTP entry is not
; ready in M8 because that adapter is intentionally not active yet.
; ---------------------------------------------------------------------------
        global af_mcp_required_ready
af_mcp_required_ready:
        AF_ENTER 32
        test    rdi, rdi
        jz      .not_ready
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_mcp_required_counts
        mov     rax, [rsp]
        cmp     rax, [rsp + 8]
        jne     .not_ready
        mov     eax, 1
        AF_LEAVE
.not_ready:
        xor     eax, eax
        AF_LEAVE

; af_mcp_required_counts(sup, out_required, out_ready) -> void
;
; Counts are bounded by CFG_MCP_COUNT and contain no identifiers.  They let the
; readiness endpoint explain a failed predicate without exposing inventory or
; process output.
        global af_mcp_required_counts
af_mcp_required_counts:
        AF_ENTER 64
        mov     [rsp], rsi
        mov     [rsp + 8], rdx
        test    rsi, rsi
        jz      .done_direct
        mov     qword [rsi], 0
        test    rdx, rdx
        jz      .done_direct
        mov     qword [rdx], 0
        test    rdi, rdi
        jz      .done_direct
        mov     rbx, rdi
        mov     rax, [rbx + MS_RT]
        test    rax, rax
        jz      .done_direct
        mov     r12, [rax + RT_CONFIG]
        test    r12, r12
        jz      .done_direct
        xor     r13, r13
        xor     r14, r14
        xor     r15, r15
.each_config:
        cmp     r13, [r12 + CFG_MCP_COUNT]
        jae     .store
        mov     rax, r13
        imul    rax, rax, MCP_SIZE
        add     rax, [r12 + CFG_MCP_SERVERS]
        mov     [rsp + 16], rax
        cmp     qword [rax + MCP_ENABLED], 0
        je      .next_config
        cmp     qword [rax + MCP_REQUIRED], 0
        je      .next_config
        inc     r14
        mov     rdi, rbx
        mov     rsi, [rax + MCP_ID]
        call    af_mcp_child_for
        test    rax, rax
        jz      .next_config
        cmp     qword [rax + MC_STATE], AF_MCP_S_READY
        jne     .next_config
        test    qword [rax + MC_FLAGS], AF_MC_F_STOPPING
        jnz     .next_config
        ; READY means the era handshake and inventory requests were queued.
        ; A required startup dependency is usable only after tools/list itself
        ; succeeded and its bounded array was committed for this batch.  The
        ; explicit bit makes a valid empty [] ready without accepting stale
        ; bytes after a failed refresh.
        test    qword [rax + MC_FLAGS], AF_MC_F_TOOLS_CURRENT
        jz      .next_config
        inc     r15
.next_config:
        inc     r13
        jmp     .each_config
.store:
        mov     rax, [rsp]
        mov     [rax], r14
        mov     rax, [rsp + 8]
        mov     [rax], r15
.done_direct:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_manual_start(af_mcp_child *child, af_mcp_supervisor *sup)
;   -> af_status
;
; An explicit start clears an earlier operator stop, but it does not erase a
; crash-loop budget.  That requires mcp.reset_crash_loop so the two controls do
; not silently become aliases.
; ---------------------------------------------------------------------------
        global af_mcp_manual_start
af_mcp_manual_start:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + MC_STATE], AF_MCP_S_CRASH_LOOP
        je      .crash_loop
        cmp     qword [rbx + MC_STATE], AF_MCP_S_DISABLED
        je      .not_ready
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .check_stdio
        ; HTTP has no PID.  Its adapter is the live-instance marker, so an
        ; operator start must not silently turn into a restart of an active
        ; endpoint.
        cmp     qword [rbx + MC_ADAPTER], 0
        jne     .closed
.check_stdio:
        cmp     qword [rbx + MC_PID], 0
        jg      .closed
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_MANUAL_STOP
        call    af_mcp_start
        AF_LEAVE
.crash_loop:
        AF_LEAVE_ERR AF_E_MCP_CRASH_LOOP
.not_ready:
        AF_LEAVE_ERR AF_E_MCP_NOT_READY
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_manual_restart(af_mcp_child *child, af_mcp_supervisor *sup)
;   -> af_status
;
; The old process is always collected before another is started.  Once it is
; gone the sweep schedules the new process immediately, without consulting the
; automatic restart mode/backoff.  Manual restart still refuses crash_loop;
; resetting that safety latch is a separate explicit operator action.
; ---------------------------------------------------------------------------
        global af_mcp_manual_restart
af_mcp_manual_restart:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + MC_STATE], AF_MCP_S_CRASH_LOOP
        je      .crash_loop
        cmp     qword [rbx + MC_STATE], AF_MCP_S_DISABLED
        je      .not_ready
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_MANUAL_STOP
        ; HTTP has no process to reap.  Invalidation below synchronously
        ; cancels its transfers and retires the adapter before the next tick
        ; starts a fresh generation.
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        je      .queue_now
        cmp     qword [rbx + MC_PID], 0
        jle     .queue_now

        or      qword [rbx + MC_FLAGS], (AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP | AF_MC_F_MANUAL_RESTART)
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_TERM_SENT
        mov     qword [rbx + MC_STATE], AF_MCP_S_RESTARTING
        mov     rdi, rbx
        call    af_mcp_invalidate_process_view
        mov     rdi, rbx
        call    af_mcp_close_stdin
        mov     rdi, rbx
        call    af_mcp_arm_shutdown_grace
        AF_LEAVE_OK

.queue_now:
        mov     rdi, rbx
        call    af_mcp_invalidate_process_view
        and     qword [rbx + MC_FLAGS], ~(AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP | AF_MC_F_TERM_SENT | AF_MC_F_MANUAL_RESTART)
        mov     qword [rbx + MC_NEXT_START], 0
        mov     qword [rbx + MC_STATE], AF_MCP_S_RESTARTING
        AF_LEAVE_OK
.crash_loop:
        AF_LEAVE_ERR AF_E_MCP_CRASH_LOOP
.not_ready:
        AF_LEAVE_ERR AF_E_MCP_NOT_READY
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_refresh_inventory(af_mcp_child *child) -> af_status
;
; Replace only inventory calls.  A pending/done operator tool test remains in
; its bounded slot and can still be observed through mcp.get.
; ---------------------------------------------------------------------------
        global af_mcp_refresh_inventory
af_mcp_refresh_inventory:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + MC_STATE], AF_MCP_S_READY
        je      .refreshable
        cmp     qword [rbx + MC_STATE], AF_MCP_S_DEGRADED
        jne     .not_ready
.refreshable:
        ; Waiting is the atomic refresh policy. Do not release a completed
        ; prefix and then discover that another list call is still pending;
        ; reject the repeated refresh without emitting duplicate requests.
        xor     r12, r12
.check_pending_inventory:
        cmp     r12, AF_MCP_MAX_CALLS
        jae     .release_start
        mov     r13, r12
        imul    r13, r13, CL_SIZE
        add     r13, rbx
        add     r13, MC_CALLS
        cmp     qword [r13 + CL_STATE], AF_MCP_CALL_FREE
        je      .next_pending
        mov     rax, [r13 + CL_KIND]
        cmp     rax, AF_MCP_CALL_TOOLS
        jb      .next_pending
        cmp     rax, AF_MCP_CALL_PROMPTS
        ja      .next_pending
        cmp     qword [r13 + CL_STATE], AF_MCP_CALL_PENDING
        je      .not_ready
.next_pending:
        inc     r12
        jmp     .check_pending_inventory

.release_start:
        xor     r12, r12
.release_inventory:
        cmp     r12, AF_MCP_MAX_CALLS
        jae     .begin
        mov     r13, r12
        imul    r13, r13, CL_SIZE
        add     r13, rbx
        add     r13, MC_CALLS
        cmp     qword [r13 + CL_STATE], AF_MCP_CALL_FREE
        je      .next_call
        mov     rax, [r13 + CL_KIND]
        cmp     rax, AF_MCP_CALL_TOOLS
        jb      .next_call
        cmp     rax, AF_MCP_CALL_PROMPTS
        ja      .next_call
        mov     rdi, r13
        call    af_mcp_call_release
.next_call:
        inc     r12
        jmp     .release_inventory
.begin:
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_LISTED
        mov     rdi, rbx
        call    af_mcp_begin_inventory
        test    rax, rax
        jns     .refresh_done
        cmp     qword [rbx + MC_STATE], AF_MCP_S_READY
        jne     .refresh_done
        mov     qword [rbx + MC_STATE], AF_MCP_S_DEGRADED
.refresh_done:
        AF_LEAVE
.not_ready:
        AF_LEAVE_ERR AF_E_MCP_NOT_READY
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_start(af_mcp_child *child, af_mcp_supervisor *sup) -> af_status
;
; Spawns and begins probing. Era is cleared first: a restarted server may be a
; different build, and speaking the previous process's protocol to it would
; produce a failure that looks like the server's fault.
; ---------------------------------------------------------------------------
        global af_mcp_start
af_mcp_start:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi

        cmp     qword [rbx + MC_STATE], AF_MCP_S_CRASH_LOOP
        je      .refused
        cmp     qword [rbx + MC_STATE], AF_MCP_S_DISABLED
        je      .refused
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .check_stdio_ownership
        ; A live adapter or transfer belongs to the prior HTTP generation.
        ; Refuse instead of cancelling it behind an ordinary `start`; manual
        ; restart/failure first retire it through process-view invalidation.
        cmp     qword [rbx + MC_ADAPTER], 0
        jne     .refused
        cmp     qword [rbx + MC_HTTP_POST], 0
        jne     .refused
        cmp     qword [rbx + MC_HTTP_GET], 0
        jne     .refused
.check_stdio_ownership:
        cmp     qword [rbx + MC_PID], 0
        jg      .refused
        ; A reaped leader may still have same-group helpers in teardown. Never
        ; reuse process state until the saved group has accepted SIGKILL or
        ; been observed absent; this also avoids signalling a stale PGID after
        ; a later spawn.
        cmp     qword [rbx + MC_PGID], 0
        jg      .refused

        ; Consume the one-shot before spawning. If this start itself fails, a
        ; later ordinary/manual restart re-probes modern rather than carrying
        ; stale fallback intent into another process lifetime.
        mov     r13, [rbx + MC_FLAGS]
        and     r13, AF_MC_F_LEGACY_NEXT
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_LEGACY_NEXT

        ; Everything negotiated or buffered below describes the old process.
        ; Preserve supervision accounting and MANUAL_STOP, but never let EOF,
        ; reaping, framing or inventory state contaminate a new process.
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_PROCESS_LIFETIME
        mov     qword [rbx + MC_ERA], AF_ERA_UNKNOWN
        mov     rdi, [rbx + MC_VERSION]
        test    rdi, rdi
        jz      .no_old_version
        call    af_free
        mov     qword [rbx + MC_VERSION], 0
.no_old_version:
        mov     qword [rbx + MC_NEXT_ID], 0
        mov     qword [rbx + MC_NEXT_START], 0
        mov     rdi, rbx
        call    af_mcp_calls_release
        lea     rdi, [rbx + MC_INBOX]
        call    af_buf_clear
        mov     qword [rbx + MC_SCAN_CURSOR], 0
        lea     rdi, [rbx + MC_OUTBOX]
        call    af_buf_clear
        lea     rdi, [rbx + MC_ERRLINE]
        call    af_buf_clear
        lea     rdi, [rbx + MC_TOOLS]
        call    af_buf_clear
        lea     rdi, [rbx + MC_RESOURCES]
        call    af_buf_clear
        lea     rdi, [rbx + MC_PROMPTS]
        call    af_buf_clear
        mov     qword [rbx + MC_OUT_CURSOR], 0
        mov     qword [rbx + MC_TOOL_COUNT], 0
        mov     qword [rbx + MC_RES_COUNT], 0
        mov     qword [rbx + MC_PROMPT_COUNT], 0
        mov     qword [rbx + MC_FETCHED_NS], 0
        mov     qword [rbx + MC_EXPIRES_NS], 0

        mov     qword [rbx + MC_STATE], AF_MCP_S_STARTING
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        je      .start_http
        mov     rdi, rbx
        call    af_mcp_spawn
        test    rax, rax
        js      .spawn_failed

        ; The pipes become loop sources. stderr is registered as well as
        ; stdout, and that is not optional: a server that fills the stderr pipe
        ; stops reading its stdin, and a supervisor that only watched the
        ; protocol pipe would wait forever on a server that was fine.
        mov     rdi, [r12 + MS_LOOP]
        mov     rsi, [rbx + MC_STDOUT_FD]
        mov     rdx, EPOLLIN
        lea     rcx, [af_mcp_on_stdout]
        mov     r8, rbx
        call    af_loop_add
        test    rax, rax
        js      .register_failed
        mov     rdi, [r12 + MS_LOOP]
        mov     rsi, [rbx + MC_STDERR_FD]
        mov     rdx, EPOLLIN
        lea     rcx, [af_mcp_on_stderr]
        mov     r8, rbx
        call    af_loop_add
        test    rax, rax
        js      .register_failed

        mov     qword [rbx + MC_STATE], AF_MCP_S_PROBING
        test    r13, r13
        jnz     .send_legacy_initialize
        mov     rdi, rbx
        call    af_mcp_send_discover
        test    rax, rax
        jz      .probe_failed
        AF_LEAVE_OK

.start_http:
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_http_start
        test    rax, rax
        js      .http_start_failed
        AF_LEAVE_OK

.send_legacy_initialize:
        mov     r14, 5000
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .legacy_timeout_ready
        mov     rcx, [rax + MCP_STARTUP_TIMEOUT]
        test    rcx, rcx
        jz      .legacy_timeout_ready
        mov     r14, rcx
.legacy_timeout_ready:
        mov     rdi, rbx
        lea     rsi, [m_initialize]
        lea     rdx, [p_initialize]
        mov     rcx, AF_MCP_CALL_INITIALIZE
        mov     r8, r14
        call    af_mcp_request
        test    rax, rax
        jz      .probe_failed
        AF_LEAVE_OK

.probe_failed:
        ; A running process with no queued era probe can never make progress.
        ; Begin the same bounded stop/reap path as any other protocol failure;
        ; the original start call still reports a useful negative status.
        mov     rdi, rbx
        mov     rsi, AF_E_MCP_PROTOCOL
        call    af_mcp_child_failed
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL

.register_failed:
        mov     [rsp], rax
        mov     qword [rbx + MC_STATE], AF_MCP_S_FAILED

        ; A process whose descriptors are not in the loop cannot be
        ; supervised.  Kill both its process group (for helpers) and the
        ; direct pid (which closes the setpgid race immediately after fork),
        ; then collect it before any pipe teardown can make it invisible.
        mov     rdi, rbx
        mov     rsi, SIGKILL
        call    af_mcp_signal
        mov     rdi, [rbx + MC_PID]
        cmp     rdi, 0
        jle     .registered_child_gone
        mov     rsi, SIGKILL
        call    af_sys_kill
.reap_registered_child:
        mov     rdi, rbx
        call    af_mcp_reap
        cmp     rax, 1
        je      .registered_child_gone
        cmp     qword [rbx + MC_PID], 0
        jle     .registered_child_gone
        mov     rdi, r12
        call    af_mcp_pause
        jmp     .reap_registered_child
.registered_child_gone:
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_teardown
        mov     rdi, rbx
        call    af_mcp_schedule_restart
        mov     rax, [rsp]
        AF_LEAVE
.spawn_failed:
        mov     [rsp], rax
        mov     qword [rbx + MC_STATE], AF_MCP_S_FAILED
        mov     rdi, rbx
        call    af_mcp_schedule_restart
        mov     rax, [rsp]
        AF_LEAVE
.http_start_failed:
        ; The adapter may have acquired a slot before a later setup step
        ; failed.  Cancel/free that generation before releasing its call and
        ; applying the ordinary bounded restart policy.
        mov     [rsp], rax
        mov     qword [rbx + MC_STATE], AF_MCP_S_FAILED
        mov     rdi, rbx
        call    af_mcp_invalidate_process_view
        mov     rdi, rbx
        call    af_mcp_schedule_restart
        mov     rax, [rsp]
        AF_LEAVE
.refused:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_send_discover(af_mcp_child *child) -> af_mcp_call *
; ---------------------------------------------------------------------------
        global af_mcp_send_discover
af_mcp_send_discover:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, 5000
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .have_timeout
        mov     rcx, [rax + MCP_STARTUP_TIMEOUT]
        test    rcx, rcx
        jz      .have_timeout
        mov     r12, rcx
.have_timeout:
        mov     rdi, rbx
        lea     rsi, [m_discover]
        lea     rdx, [p_discover]
        mov     rcx, AF_MCP_CALL_DISCOVER
        mov     r8, r12
        call    af_mcp_request
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_teardown(af_mcp_child *child, af_mcp_supervisor *sup) -> void
;
; Removes the pipes from the loop and closes them. Deregistering before closing
; matters for the same reason it does everywhere else: a descriptor closed
; while still registered is dropped from the interest set by the kernel, but an
; event already queued for it would still be delivered.
; ---------------------------------------------------------------------------
        global af_mcp_teardown
af_mcp_teardown:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi

        ; HTTP has no process group or pipe registrations.  Its teardown is
        ; nevertheless process-view teardown: invalidate cancels both transfer
        ; slots before releasing any correlated calls.
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        je      .invalidate

        ; wait4 owns only the direct leader. A helper can keep the original
        ; group alive after MC_PID becomes zero, so retire group ownership here
        ; before any restart is allowed. SIGKILL cannot be caught or ignored;
        ; ESRCH is normalized to success by af_mcp_signal. On any other error
        ; retain MC_PGID so the sweep retries instead of risking an orphan or
        ; later signalling a numerically reused group.
        cmp     qword [rbx + MC_PGID], 0
        jle     .group_done
        mov     rdi, rbx
        mov     rsi, SIGKILL
        call    af_mcp_signal
        test    rax, rax
        js      .group_done
        mov     qword [rbx + MC_PGID], 0
.group_done:
        test    r12, r12
        jz      .close

        mov     rax, [rbx + MC_STDOUT_FD]
        cmp     rax, 0
        jl      .no_stdout
        mov     rdi, [r12 + MS_LOOP]
        mov     rsi, rax
        call    af_loop_del
.no_stdout:
        mov     rax, [rbx + MC_STDERR_FD]
        cmp     rax, 0
        jl      .close
        mov     rdi, [r12 + MS_LOOP]
        mov     rsi, rax
        call    af_loop_del
.close:
        mov     rdi, rbx
        call    af_mcp_close_pipes
.invalidate:
        mov     rdi, rbx
        call    af_mcp_invalidate_process_view
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_invalidate_process_view(af_mcp_child *child) -> void
;
; Calls, inventory and the negotiated era/version are scoped to one stdio
; process. Invalidate them as soon as shutdown/failure begins, not only when a
; replacement is spawned: a restart.mode=never child may stay stopped forever
; and must not continue to advertise state from a process that cannot answer.
; ---------------------------------------------------------------------------
af_mcp_invalidate_process_view:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        ; libcurl completion owns a borrowed CL pointer.  Retire the HTTP
        ; generation and synchronously cancel POST/GET before freeing calls;
        ; reversing this order would make cancellation completion dereference
        ; a released slot.
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .release_calls
        mov     rdi, rbx
        mov     rsi, AF_E_CLOSED
        call    af_mcp_http_stop
.release_calls:
        mov     rdi, rbx
        call    af_mcp_calls_release
        mov     qword [rbx + MC_ERA], AF_ERA_UNKNOWN
        mov     rdi, [rbx + MC_VERSION]
        test    rdi, rdi
        jz      .no_version
        call    af_free
        mov     qword [rbx + MC_VERSION], 0
.no_version:
        lea     rdi, [rbx + MC_TOOLS]
        call    af_buf_clear
        lea     rdi, [rbx + MC_RESOURCES]
        call    af_buf_clear
        lea     rdi, [rbx + MC_PROMPTS]
        call    af_buf_clear
        mov     qword [rbx + MC_TOOL_COUNT], 0
        mov     qword [rbx + MC_RES_COUNT], 0
        mov     qword [rbx + MC_PROMPT_COUNT], 0
        mov     qword [rbx + MC_FETCHED_NS], 0
        mov     qword [rbx + MC_EXPIRES_NS], 0
        mov     qword [rbx + MC_SCAN_CURSOR], 0
        and     qword [rbx + MC_FLAGS], ~(AF_MC_F_PROBED | AF_MC_F_LISTED | AF_MC_F_TOOLS_CURRENT)
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_stop(af_mcp_child *child, af_mcp_supervisor *sup, i64 manual)
;   -> af_status
;
; The shutdown sequence from docs/MCP_COMPATIBILITY.md 10, condensed to what a
; stdio server needs: stop accepting calls, close its stdin so a server that
; reads to EOF can finish on its own, ask it to stop, and then insist.
;
; `manual` records that an operator did this, so the supervisor does not helpfully
; start it again.
; ---------------------------------------------------------------------------
        global af_mcp_stop
af_mcp_stop:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        ; These states are operator/configuration latches, not process states.
        ; stop must not rewrite either one and thereby let a later start bypass
        ; enabled:false or the crash-loop manual-reset requirement.
        cmp     qword [rbx + MC_STATE], AF_MCP_S_DISABLED
        je      .disabled
        cmp     qword [rbx + MC_STATE], AF_MCP_S_CRASH_LOOP
        je      .crash_loop

        or      qword [rbx + MC_FLAGS], AF_MC_F_STOPPING
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_TERM_SENT
        test    r13, r13
        jz      .not_manual
        or      qword [rbx + MC_FLAGS], AF_MC_F_MANUAL_STOP
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_LEGACY_NEXT
        mov     qword [rbx + MC_STATE], AF_MCP_S_STOPPED
.not_manual:

        mov     rdi, rbx
        call    af_mcp_invalidate_process_view
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        je      .finish_http
        mov     rdi, rbx
        call    af_mcp_close_stdin

        cmp     qword [rbx + MC_PID], 0
        jle     .finish

        ; Closing stdin may be enough, so collect once without signalling.
        ; Anything still running receives its configured grace in the sweep.
        mov     rdi, rbx
        call    af_mcp_reap
        cmp     rax, 0
        jle     .pending

.finish:
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_teardown
        mov     qword [rbx + MC_STATE], AF_MCP_S_STOPPED
        and     qword [rbx + MC_FLAGS], ~(AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP | AF_MC_F_TERM_SENT | AF_MC_F_MANUAL_RESTART)
        AF_LEAVE_OK
.finish_http:
        ; af_mcp_invalidate_process_view already cancelled both transfers and
        ; freed the adapter.  There is no PID/grace/reap phase for HTTP.
        mov     qword [rbx + MC_STATE], AF_MCP_S_STOPPED
        and     qword [rbx + MC_FLAGS], ~(AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP | AF_MC_F_TERM_SENT | AF_MC_F_MANUAL_RESTART)
        AF_LEAVE_OK
.pending:
        ; Still alive. It stays registered so its remaining output is read.
        ; Only after the configured stdin-EOF grace does the sweep send TERM.
        mov     rdi, rbx
        call    af_mcp_arm_shutdown_grace
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.disabled:
        AF_LEAVE_ERR AF_E_MCP_NOT_READY
.crash_loop:
        AF_LEAVE_ERR AF_E_MCP_CRASH_LOOP

; ---------------------------------------------------------------------------
; af_mcp_child_failed(af_mcp_child *child, af_status why) -> void
;
; The child stopped being usable. Whether it is restarted, and when, is the
; budget's decision.
; ---------------------------------------------------------------------------
        global af_mcp_child_failed
af_mcp_child_failed:
        AF_ENTER 48
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        cmp     qword [rbx + MC_STATE], AF_MCP_S_CRASH_LOOP
        je      .done
        cmp     qword [rbx + MC_STATE], AF_MCP_S_DISABLED
        je      .done
        ; Preserve the first real failure across a later stdout EOF/HUP.  The
        ; child may react to our stdin close by exiting zero, but that does not
        ; turn protocol corruption, a write error, or a probe failure into a
        ; clean process exit.
        cmp     rsi, AF_E_EOF
        je      .cause_recorded
        or      qword [rbx + MC_FLAGS], AF_MC_F_PROCESS_FAILURE
.cause_recorded:
        test    qword [rbx + MC_FLAGS], AF_MC_F_STOPPING
        jnz     .done
        mov     qword [rbx + MC_STATE], AF_MCP_S_FAILED
        mov     rdi, rbx
        call    af_mcp_invalidate_process_view

        test    qword [rbx + MC_FLAGS], AF_MC_F_MANUAL_STOP
        jnz     .done
        cmp     qword [rbx + MC_PID], 0
        jle     .schedule

        ; Do not put a live process into RESTARTING: af_mcp_start correctly
        ; rejects MC_PID > 0, which would otherwise strand the child forever.
        ; Stop it asynchronously; the sweep spends restart budget only after
        ; wait4 confirms the old process is gone.
        or      qword [rbx + MC_FLAGS], (AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP)
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_TERM_SENT
        mov     rdi, rbx
        call    af_mcp_close_stdin
        mov     rdi, rbx
        call    af_mcp_arm_shutdown_grace
        jmp     .done
.schedule:
        test    qword [rbx + MC_FLAGS], AF_MC_F_LEGACY_NEXT
        jz      .policy_schedule
        mov     qword [rbx + MC_NEXT_START], 0
        mov     qword [rbx + MC_STATE], AF_MCP_S_RESTARTING
        jmp     .done
.policy_schedule:
        mov     rdi, rbx
        call    af_mcp_schedule_restart
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_schedule_restart(af_mcp_child *child) -> void
;
; The sliding window and the bounded backoff (M8 DoD 9).
;
; The window is what makes "crash loop" mean something other than "has ever
; failed": a server that fails once a day for a week is not looping, and a
; server that fails four times in ten seconds is — even though the second one
; has failed fewer times in total.
; ---------------------------------------------------------------------------
        global af_mcp_schedule_restart
af_mcp_schedule_restart:
        AF_ENTER 64
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, [rbx + MC_CFG]
        test    r12, r12
        jz      .done

        ; `never` means exactly that.
        mov     rax, [r12 + MCP_RESTART_MODE]
        cmp     rax, AF_RESTART_NEVER
        je      .done

        call    af_monotonic_now
        mov     [rsp], rax                     ; now_ns

        ; Compute the inclusive lower bound of [now-window, now]. A zero
        ; window is treated conservatively as an unexpiring history; validated
        ; configurations normally provide a positive window.
        mov     rax, [r12 + MCP_WINDOW_MS]
        test    rax, rax
        jz      .zero_cutoff
        mov     rdi, rax
        mov     rsi, NS_PER_MS
        lea     rdx, [rsp + 8]                 ; window_ns
        call    af_mul_size
        test    rax, rax
        js      .crash_loop
        mov     rax, [rsp]
        cmp     rax, [rsp + 8]
        jb      .zero_cutoff
        sub     rax, [rsp + 8]
        mov     [rsp + 16], rax                ; cutoff_ns
        jmp     .compact
.zero_cutoff:
        mov     qword [rsp + 16], 0

        ; Compact every surviving timestamp to the front. Equal-to-cutoff
        ; survives: the contract is the closed interval [now-window, now].
.compact:
        mov     r15, [rbx + MC_RESTARTS]
        cmp     r15, AF_MCP_RESTART_HISTORY_MAX
        ja      .crash_loop                    ; corrupted count must not OOB
        xor     r13d, r13d                     ; source index
        xor     r14d, r14d                     ; retained count
.compact_next:
        cmp     r13, r15
        jae     .compacted
        mov     rax, [rbx + MC_RESTART_HISTORY + r13 * 8]
        cmp     rax, [rsp + 16]
        jb      .compact_skip
        mov     [rbx + MC_RESTART_HISTORY + r14 * 8], rax
        inc     r14
.compact_skip:
        inc     r13
        jmp     .compact_next
.compacted:
        mov     [rbx + MC_RESTARTS], r14
        test    r14, r14
        jz      .empty_window
        mov     rax, [rbx + MC_RESTART_HISTORY]
        mov     [rbx + MC_WINDOW_START], rax
        jmp     .window_ready
.empty_window:
        mov     qword [rbx + MC_WINDOW_START], 0
        ; No restart remains inside the window, so this is a new incident and
        ; exponential backoff begins at the configured base again.
        mov     qword [rbx + MC_BACKOFF_MS], 0
.window_ready:

        mov     rax, [r12 + MCP_MAX_RESTARTS]
        test    rax, rax
        jz      .crash_loop                     ; no budget at all
        cmp     rax, AF_MCP_RESTART_HISTORY_MAX
        ja      .crash_loop                     ; reject unsafe live snapshots
        cmp     r14, rax
        jae     .crash_loop
        mov     rax, [rsp]
        mov     [rbx + MC_RESTART_HISTORY + r14 * 8], rax
        inc     r14
        mov     [rbx + MC_RESTARTS], r14
        cmp     r14, 1
        jne     .history_recorded
        mov     [rbx + MC_WINDOW_START], rax
.history_recorded:

        ; Backoff: the configured base, doubled each time, bounded. Without the
        ; bound a server down for an hour would eventually be retried once a
        ; century; without the doubling it would be retried every second for
        ; the whole hour.
        mov     r14, [r12 + MCP_BACKOFF_MS]
        mov     rax, [rbx + MC_BACKOFF_MS]
        test    rax, rax
        jnz     .double
        mov     rax, r14
        jmp     .bound
.double:
        add     rax, rax
        jc      .cap
.bound:
        mov     rcx, [r12 + MCP_MAX_BACKOFF_MS]
        cmp     rax, rcx
        jbe     .backoff_ready
.cap:
        mov     rax, rcx
.backoff_ready:
        mov     [rbx + MC_BACKOFF_MS], rax
        mov     rdi, rax
        mov     rsi, NS_PER_MS
        lea     rdx, [rsp + 24]
        call    af_mul_size
        test    rax, rax
        js      .deadline_saturated
        mov     rdi, [rsp]
        mov     rsi, [rsp + 24]
        lea     rdx, [rsp + 32]
        call    af_add_size
        test    rax, rax
        js      .deadline_saturated
        mov     rax, [rsp + 32]
        mov     [rbx + MC_NEXT_START], rax
        mov     qword [rbx + MC_STATE], AF_MCP_S_RESTARTING
        AF_LEAVE

.deadline_saturated:
        ; Never wrap a deadline into the past and spin. This can only occur
        ; near monotonic u64 exhaustion, but saturation is deterministic.
        mov     qword [rbx + MC_NEXT_START], -1
        mov     qword [rbx + MC_STATE], AF_MCP_S_RESTARTING
        AF_LEAVE

.crash_loop:
        ; The budget is spent. Nothing restarts it until an operator says so
        ; (M8 DoD 9), because a supervisor that kept trying would turn one
        ; broken server into a fork bomb.
        mov     qword [rbx + MC_STATE], AF_MCP_S_CRASH_LOOP
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_reset(af_mcp_child *child) -> af_status
;
; The manual reset. Clears the budget and the backoff so the next sweep may
; start the child again.
; ---------------------------------------------------------------------------
        global af_mcp_reset
af_mcp_reset:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + MC_PID], 0
        jg      .running
        cmp     qword [rbx + MC_PGID], 0
        jg      .running
        cmp     qword [rbx + MC_STATE], AF_MCP_S_CRASH_LOOP
        jne     .not_ready
        mov     qword [rbx + MC_RESTARTS], 0
        mov     qword [rbx + MC_WINDOW_START], 0
        mov     qword [rbx + MC_BACKOFF_MS], 0
        mov     qword [rbx + MC_NEXT_START], 0
        mov     qword [rbx + MC_SCAN_CURSOR], 0
        lea     rdi, [rbx + MC_RESTART_HISTORY]
        mov     rsi, AF_MCP_RESTART_HISTORY_BYTES
        call    af_mem_zero
        and     qword [rbx + MC_FLAGS], ~(AF_MC_F_MANUAL_STOP | AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP | AF_MC_F_TERM_SENT | AF_MC_F_MANUAL_RESTART | AF_MC_F_LEGACY_NEXT)
        ; STOPPED is reserved for the first automatic start (MC_STARTS == 0).
        ; A crash-loop reset has already started before, so put it on the
        ; normal due-restart path instead.
        mov     qword [rbx + MC_STATE], AF_MCP_S_RESTARTING
.done:
        AF_LEAVE_OK
.running:
        AF_LEAVE_ERR AF_E_CLOSED
.not_ready:
        AF_LEAVE_ERR AF_E_MCP_NOT_READY
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; The loop handlers.
; ---------------------------------------------------------------------------
        global af_mcp_on_stdout
af_mcp_on_stdout:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, rbx
        call    af_mcp_read_stdout
        mov     r12, rax
        test    r12, r12
        js      .failed
        mov     rdi, rbx
        call    af_mcp_advance
.done:
        AF_LEAVE
.failed:
        cmp     r12, AF_E_EOF
        jne     .drop
        ; Drop the HUP source before beginning bounded shutdown, or epoll would
        ; keep returning it while the child remains alive through its grace.
        or      qword [rbx + MC_FLAGS], AF_MC_F_EOF
.drop:
        mov     rdi, rbx
        mov     rsi, MC_STDOUT_FD
        call    af_mcp_drop_pipe_source
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_child_failed
        AF_LEAVE

        global af_mcp_on_stderr
af_mcp_on_stderr:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, rbx
        call    af_mcp_read_stderr
        mov     r12, rax
        test    r12, r12
        jns     .done
        ; Flush whatever was mid-line, so the last thing a failing server said
        ; is not lost for want of a newline.
        mov     rdi, rbx
        call    af_mcp_flush_errline
        mov     rdi, rbx
        mov     rsi, MC_STDERR_FD
        call    af_mcp_drop_pipe_source
        cmp     r12, AF_E_EOF
        je      .done
        ; An actual read failure means stderr can no longer be drained.  A
        ; child that continues writing it could then deadlock the protocol.
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_child_failed
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_drop_pipe_source(af_mcp_child *child, u64 fd_offset) -> void
;
; Removes one child pipe from the owning loop, closes it exactly once, and
; stores -1.  MC_SUP is BORROWED solely to reach the epoll registration.
; ---------------------------------------------------------------------------
af_mcp_drop_pipe_source:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, [rbx + r12]
        cmp     r13, 0
        jl      .done
        mov     rax, [rbx + MC_SUP]
        test    rax, rax
        jz      .close
        mov     rdi, [rax + MS_LOOP]
        test    rdi, rdi
        jz      .close
        mov     rsi, r13
        call    af_loop_del
.close:
        mov     rdi, r13
        call    af_sys_close
        mov     qword [rbx + r12], -1
.done:
        AF_LEAVE

        global af_mcp_on_stdin_writable
af_mcp_on_stdin_writable:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        call    af_mcp_write_stdin
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_on_tick(void *ctx, i64 fd, u64 events) -> void
;
; The sweep: reap what has exited, expire calls nobody answered, escalate a
; shutdown that is taking too long, and start what is due.
; ---------------------------------------------------------------------------
        global af_mcp_on_tick
af_mcp_on_tick:
        AF_ENTER 64
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi

.drain:
        mov     rdi, [rbx + MS_TIMER_FD]
        lea     rsi, [rsp]
        mov     rdx, 8
        call    af_sys_read
        cmp     rax, 0
        jg      .drain

        call    af_monotonic_now
        mov     [rsp + 16], rax

        xor     r12, r12
.each:
        cmp     r12, [rbx + MS_COUNT]
        jae     .done
        mov     r13, r12
        imul    r13, r13, MC_SIZE
        add     r13, rbx
        add     r13, MS_CHILDREN

        mov     rdi, r13
        mov     rsi, rbx
        mov     rdx, [rsp + 16]
        call    af_mcp_sweep_child
        inc     r12
        jmp     .each
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_sweep_child(af_mcp_child *child, af_mcp_supervisor *sup, u64 now_ns)
;   -> void
; ---------------------------------------------------------------------------
        global af_mcp_sweep_child
af_mcp_sweep_child:
        AF_ENTER 48
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        ; Anything that has exited is collected, whatever state it was in. A
        ; process nobody waits for is a zombie regardless of how it ended.
        cmp     qword [rbx + MC_PID], 0
        jle     .no_child
        mov     rdi, rbx
        call    af_mcp_reap
        cmp     rax, 1
        jne     .running
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_teardown
        test    qword [rbx + MC_FLAGS], AF_MC_F_STOPPING
        jz      .unexpected_exit
        test    qword [rbx + MC_FLAGS], AF_MC_F_RESTART_AFTER_STOP
        jz      .stopped_after_reap
        mov     rax, [rbx + MC_FLAGS]
        and     qword [rbx + MC_FLAGS], ~(AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP | AF_MC_F_TERM_SENT | AF_MC_F_MANUAL_RESTART)
        test    qword [rbx + MC_FLAGS], AF_MC_F_MANUAL_STOP
        jnz     .stopped_after_reap
        test    rax, AF_MC_F_LEGACY_NEXT
        jnz     .internal_legacy_restart_due
        test    rax, AF_MC_F_MANUAL_RESTART
        jnz     .manual_restart_due
        ; stdout EOF can start the bounded failure-stop path before wait4
        ; reports the child's actual status. Once reaped, a clean exit still
        ; obeys restart.mode: only `always` restarts it. Other causes that use
        ; this same stop path (protocol/write/probe failures) remain failures
        ; even when a cooperative child reacts to stdin EOF by exiting zero.
        test    rax, AF_MC_F_EOF
        jz      .restart_after_stop
        test    rax, AF_MC_F_PROCESS_FAILURE
        jnz     .restart_after_stop
        cmp     qword [rbx + MC_LAST_EXIT], 0
        jne     .restart_after_stop
        mov     rcx, [rbx + MC_CFG]
        test    rcx, rcx
        jz      .stopped_after_reap
        cmp     qword [rcx + MCP_RESTART_MODE], AF_RESTART_ALWAYS
        jne     .stopped_after_reap
.restart_after_stop:
        mov     rdi, rbx
        call    af_mcp_schedule_restart
        jmp     .no_child
.manual_restart_due:
        mov     qword [rbx + MC_NEXT_START], 0
        mov     qword [rbx + MC_STATE], AF_MCP_S_RESTARTING
        jmp     .no_child
.internal_legacy_restart_due:
        ; Do not spend or consult automatic restart budget. This is completion
        ; of era selection, not recovery from a process crash.
        mov     qword [rbx + MC_NEXT_START], 0
        mov     qword [rbx + MC_STATE], AF_MCP_S_RESTARTING
        jmp     .no_child
.stopped_after_reap:
        mov     qword [rbx + MC_STATE], AF_MCP_S_STOPPED
        and     qword [rbx + MC_FLAGS], ~(AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP | AF_MC_F_TERM_SENT | AF_MC_F_MANUAL_RESTART)
        jmp     .no_child
.unexpected_exit:
        ; wait4 status zero is a normal exit(0). `on_failure` and `never`
        ; therefore stop cleanly; only `always` spends restart budget for it.
        cmp     qword [rbx + MC_LAST_EXIT], 0
        jne     .unexpected_failure
        mov     rax, [rbx + MC_CFG]
        test    rax, rax
        jz      .clean_exit
        cmp     qword [rax + MCP_RESTART_MODE], AF_RESTART_ALWAYS
        je      .unexpected_failure
.clean_exit:
        mov     qword [rbx + MC_STATE], AF_MCP_S_STOPPED
        jmp     .no_child
.unexpected_failure:
        mov     rdi, rbx
        mov     rsi, AF_E_MCP_SPAWN
        call    af_mcp_child_failed
        jmp     .no_child

.running:
        ; Advance stdin grace -> SIGTERM wait -> SIGKILL without blocking the
        ; event loop.
        test    qword [rbx + MC_FLAGS], AF_MC_F_STOPPING
        jz      .calls
        mov     rdi, rbx
        mov     rsi, r13
        call    af_mcp_advance_shutdown
        jmp     .calls

.no_child:
        ; A prior group kill can fail transiently even though the direct child
        ; was already collected. Retry centrally and do not advance calls or
        ; start a replacement while ownership of the old PGID remains.
        cmp     qword [rbx + MC_PGID], 0
        jle     .calls
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_teardown
        cmp     qword [rbx + MC_PGID], 0
        jg      .done
.calls:
        ; stdin is nonblocking, but it is not a permanent EPOLLOUT source.  A
        ; write that reached EAGAIN therefore gets one bounded retry per
        ; supervisor tick while bytes remain queued.  af_mcp_write_stdin drains
        ; at most the bounded outbox and returns immediately on the next
        ; EAGAIN, so a slow child cannot monopolise the loop.
        test    qword [rbx + MC_FLAGS], AF_MC_F_STDIN_OPEN
        jz      .sweep_calls
        lea     rdi, [rbx + MC_OUTBOX]
        call    af_buf_len
        cmp     rax, [rbx + MC_OUT_CURSOR]
        jbe     .sweep_calls
        mov     rdi, rbx
        call    af_mcp_write_stdin
        test    rax, rax
        jns     .sweep_calls
        mov     rsi, rax
        mov     rdi, rbx
        call    af_mcp_child_failed
.sweep_calls:
        mov     rdi, rbx
        mov     rsi, r13
        call    af_mcp_sweep_calls
        test    rax, rax
        jns     .calls_swept
        mov     rsi, rax
        mov     rdi, rbx
        call    af_mcp_child_failed
        jmp     .calls_advanced
.calls_swept:
        mov     rdi, rbx
        call    af_mcp_advance
.calls_advanced:

        ; Positive HTTP cache TTLs are refreshed lazily from the existing
        ; supervisor tick once the serial inventory batch is complete. A zero
        ; or absent TTL records expires==fetched and is intentionally not
        ; polled; the next explicit discover is the access that refreshes it.
        cmp     qword [rbx + MC_TRANSPORT], AF_TRANSPORT_STREAMABLE_HTTP
        jne     .restart_due
        test    qword [rbx + MC_FLAGS], AF_MC_F_HTTP_PROMPTS_ISSUED
        jz      .restart_due
        cmp     qword [rbx + MC_HTTP_POST], 0
        jne     .restart_due
        mov     rax, [rbx + MC_EXPIRES_NS]
        cmp     rax, [rbx + MC_FETCHED_NS]
        jbe     .restart_due
        cmp     r13, rax
        jb      .restart_due
        mov     qword [rbx + MC_EXPIRES_NS], 0
        mov     rdi, rbx
        call    af_mcp_refresh_inventory

.restart_due:

        ; A restart that is due.
        cmp     qword [rbx + MC_STATE], AF_MCP_S_RESTARTING
        jne     .maybe_first_start
        mov     rax, [rbx + MC_NEXT_START]
        cmp     r13, rax
        jb      .done
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_start
        jmp     .done

.maybe_first_start:
        ; A server that has never been started, and is not disabled, is started
        ; on the first sweep. Starting it during initialisation would mean a
        ; configuration naming an unreachable command stopped the daemon.
        cmp     qword [rbx + MC_STATE], AF_MCP_S_STOPPED
        jne     .done
        test    qword [rbx + MC_FLAGS], AF_MC_F_MANUAL_STOP
        jnz     .done
        cmp     qword [rbx + MC_STARTS], 0
        jne     .done
        mov     rdi, rbx
        mov     rsi, r12
        call    af_mcp_start
.done:
        AF_LEAVE
