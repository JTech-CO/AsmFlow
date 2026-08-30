; AsmFlow — MCP stdio supervision.
;
; A supervised MCP server is a child process AsmFlow spawns, talks JSON-RPC to
; over pipes, watches, restarts within a budget, and shuts down without leaving
; a zombie. `docs/MCP_COMPATIBILITY.md` 10 is the state machine; this header is
; the storage it runs on.
;
; Three properties shape the layout.
;
; The child is executed, never interpreted. argv is a literal vector from the
; configuration and the environment is built from an allowlist, so there is no
; string for a shell to re-parse and no variable reaching the child that an
; operator did not name (M8 DoD 1 and 2).
;
; Both output pipes are drained continuously. A server that floods stderr must
; not be able to stall the protocol: if AsmFlow stopped reading stderr the
; child would block writing to it, stop reading stdin, and the supervision
; would deadlock with nothing obviously wrong anywhere (M8 DoD 7).
;
; Era is decided once per process lifetime and re-probed after a restart
; (M8 DoD 5). It is stored on the child rather than on the configuration for
; the same reason routing state is: it describes this process, not the
; operator's intent.

%ifndef ASMFLOW_MCP_INC
%define ASMFLOW_MCP_INC

%include "mcp_http.inc"

; --- capacity ---------------------------------------------------------------
; The schema allows 256 configured MCP servers.  M8 instantiates only the
; stdio subset, but the table still has to be large enough when every accepted
; entry is stdio: silently dropping the tail would make validated operator
; intent disappear.  Runtime descriptor capacity remains independently
; bounded by the shared event loop (two sources per running stdio child).
%define AF_MCP_MAX_CHILDREN 256

; In-flight JSON-RPC calls per child. AsmFlow is a supervisor rather than an
; agent runtime: it probes, lists, and — on an operator's explicit
; confirmation — tests one tool. Eight is generous for that and bounded.
%define AF_MCP_MAX_CALLS 8

; How much of one inventory list AsmFlow will hold, per kind.
%define AF_MCP_INVENTORY_MAX (1024 * 1024)

; The stderr ring: what is kept for an operator to read. Older lines are
; dropped rather than newer ones, because a server that is failing says the
; useful thing last.
%define AF_MCP_STDERR_KEEP (64 * 1024)

; One read from a child pipe.
%define AF_MCP_READ_CHUNK 65536

; Hard buffer ceilings corresponding to the largest values accepted by the
; configuration schema.  Buffers grow lazily, so these numbers bound an
; adversarial child without preallocating them for every configured server.
;
; The inbox needs one complete read beyond the frame ceiling: a line may sit
; exactly at the configured maximum without its newline, and the next read can
; contain that newline plus the beginning of the following frame.  Framing
; consumes or enters DISCARDING immediately after that append.
%define AF_MCP_FRAME_HARD_MAX       (64 * 1024 * 1024)
%define AF_MCP_INBOX_MAX            (AF_MCP_FRAME_HARD_MAX + AF_MCP_READ_CHUNK)
%define AF_MCP_STDERR_LINE_HARD_MAX (1024 * 1024)

; execve environments are attacker-amplifiable through secret mappings: many
; child names may read the same host variable. Bound both one NAME=VALUE entry
; and the complete string block before allocation. The 1 MiB aggregate leaves
; headroom under Linux ARG_MAX for the separately bounded argv vector.
%define AF_MCP_ENV_ENTRY_MAX (128 * 1024)
%define AF_MCP_ENV_BLOCK_MAX (1024 * 1024)

; A restart budget is a genuine sliding window.  Configuration bounds the
; budget at 100, so keeping the accepted restart timestamps inline is both
; deterministic and bounded (800 bytes per configured child).
%define AF_MCP_RESTART_HISTORY_MAX   100
%define AF_MCP_RESTART_HISTORY_BYTES (AF_MCP_RESTART_HISTORY_MAX * 8)

; Shutdown is staged: stdin EOF gets the configured grace first, then SIGTERM
; gets a short bounded wait before SIGKILL.  The schema bounds the configured
; grace at ten minutes.
%define AF_MCP_SHUTDOWN_GRACE_MAX_MS 600000
%define AF_MCP_TERM_WAIT_MS          2000
%define AF_MCP_SHUTDOWN_POLL_MS      10

; --- supervision states -----------------------------------------------------
; docs/MCP_COMPATIBILITY.md 10:
;   stopped -> starting -> probing -> ready
;                       \-> degraded
;                       \-> failed -> restarting -> starting
;                                  \-> crash_loop
%define AF_MCP_S_STOPPED     0
%define AF_MCP_S_STARTING    1
%define AF_MCP_S_PROBING     2
%define AF_MCP_S_READY       3
%define AF_MCP_S_DEGRADED    4
%define AF_MCP_S_FAILED      5
%define AF_MCP_S_RESTARTING  6
%define AF_MCP_S_CRASH_LOOP  7
%define AF_MCP_S_DISABLED    8
%define AF_MCP_S_COUNT       9

; --- call kinds -------------------------------------------------------------
%define AF_MCP_CALL_DISCOVER   0
%define AF_MCP_CALL_INITIALIZE 1
%define AF_MCP_CALL_TOOLS      2
%define AF_MCP_CALL_RESOURCES  3
%define AF_MCP_CALL_PROMPTS    4
%define AF_MCP_CALL_TOOL_TEST  5
%define AF_MCP_CALL_COUNT      6

%define AF_MCP_CALL_FREE    0
%define AF_MCP_CALL_PENDING 1
%define AF_MCP_CALL_DONE    2

; --- af_mcp_call (96 bytes) -------------------------------------------------
;   +0   state       AF_MCP_CALL_*
;   +8   id          the JSON-RPC id AsmFlow assigned
;   +16  kind        AF_MCP_CALL_*
;   +24  deadline_ns monotonic; a call past it is abandoned, not waited on
;   +32  status      af_status once complete
;   +40  result      af_buffer holding the raw `result` or `error` member
;   +72  error_code  the JSON-RPC error code, or 0
;   +80  http_status response status for Streamable HTTP, or 0 for stdio
;   +88  flags       transport-normalized evidence/cancellation flags
%define CL_STATE      0
%define CL_ID         8
%define CL_KIND       16
%define CL_DEADLINE   24
%define CL_STATUS     32
%define CL_RESULT     40
%define CL_ERROR_CODE 72
%define CL_HTTP_STATUS 80
%define CL_FLAGS       88
%define CL_SIZE        96

%define AF_MCP_CL_F_HTTP             1
%define AF_MCP_CL_F_RECOGNIZED       2
%define AF_MCP_CL_F_BARE_REFUSAL     4
%define AF_MCP_CL_F_VERSION_ERROR    8
%define AF_MCP_CL_F_SSE              16
%define AF_MCP_CL_F_FINAL_SEEN       32
%define AF_MCP_CL_F_CANCELLED        64
%define AF_MCP_CL_F_HEADER_MISMATCH  128

; --- af_mcp_child -----------------------------------------------------------
; One supervised server. Fixed size and allocated from a table, so a burst of
; restarts cannot fragment the heap.
;
;   +0    id            OWNED copy of the configured id; the key for state that
;                       has to survive a reload
;   +8    cfg           af_cfg_mcp * — BORROWED from the current snapshot
;   +16   state         AF_MCP_S_*
;   +24   pid           0 when nothing is running
;   +32   stdin_fd      our end of the child's stdin, or -1
;   +40   stdout_fd
;   +48   stderr_fd
%define MC_ID          0
%define MC_CFG         8
%define MC_STATE       16
%define MC_PID         24
%define MC_STDIN_FD    32
%define MC_STDOUT_FD   40
%define MC_STDERR_FD   48

;   +56   inbox         af_buffer: stdout bytes not yet framed into a line
;   +88   outbox        af_buffer: JSON-RPC lines not yet written to stdin
;   +120  out_cursor    how much of the outbox has already been written
;   +128  errline       af_buffer: the stderr line being accumulated
;   +160  errlog        af_buffer: the bounded tail an operator can read
%define MC_INBOX       56
%define MC_OUTBOX      88
%define MC_OUT_CURSOR  120
%define MC_ERRLINE     128
%define MC_ERRLOG      160

;   +192  era           AF_ERA_*, decided once per process lifetime
;   +200  version       OWNED copy of the negotiated protocol version, or NULL
;   +208  next_id       the JSON-RPC id counter for this process
;   +216  calls         af_mcp_call[AF_MCP_MAX_CALLS]
%define MC_ERA         192
%define MC_VERSION     200
%define MC_NEXT_ID     208
%define MC_CALLS       216
%define MC_AFTER_CALLS (MC_CALLS + AF_MCP_MAX_CALLS * CL_SIZE)

; Inventory arrays, compact-encoded after bounded parsing of the kind-specific
; result member. Re-encoding preserves JSON array order and value semantics
; while excluding protocol-envelope fields from the operator-facing cache.
; Each af_buffer owns its bytes; refresh builds a separate replacement and
; transfers it only after validation and allocation both succeed.
%define MC_TOOLS       (MC_AFTER_CALLS + 0)      ; af_buffer
%define MC_RESOURCES   (MC_AFTER_CALLS + 32)
%define MC_PROMPTS     (MC_AFTER_CALLS + 64)
%define MC_TOOL_COUNT  (MC_AFTER_CALLS + 96)
%define MC_RES_COUNT   (MC_AFTER_CALLS + 104)
%define MC_PROMPT_COUNT (MC_AFTER_CALLS + 112)
%define MC_FETCHED_NS  (MC_AFTER_CALLS + 120)
%define MC_EXPIRES_NS  (MC_AFTER_CALLS + 128)

; Supervision accounting.
;   restarts        within the current window
;   window_start_ns when the current window began
;   backoff_ms      the current wait, doubled on each restart and bounded
;   next_start_ns   the earliest a restart may happen
;   starts          total spawns since boot
;   exits           total reaps
;   last_exit       the wait status of the most recent exit
;   last_signal     the signal that ended it, or 0
%define MC_RESTARTS       (MC_AFTER_CALLS + 136)
%define MC_WINDOW_START   (MC_AFTER_CALLS + 144)
%define MC_BACKOFF_MS     (MC_AFTER_CALLS + 152)
%define MC_NEXT_START     (MC_AFTER_CALLS + 160)
%define MC_STARTS         (MC_AFTER_CALLS + 168)
%define MC_EXITS          (MC_AFTER_CALLS + 176)
%define MC_LAST_EXIT      (MC_AFTER_CALLS + 184)
%define MC_LAST_SIGNAL    (MC_AFTER_CALLS + 192)

; What the child did that AsmFlow refused to accept. A stdout line that is not
; JSON-RPC is protocol contamination and is counted, never ignored: a
; supervisor that tolerated log lines on the protocol pipe would hide exactly
; the failure that corrupts a session (M8 DoD 6).
%define MC_CONTAMINATED   (MC_AFTER_CALLS + 200)
%define MC_OVERSIZED      (MC_AFTER_CALLS + 208)
%define MC_STDERR_BYTES   (MC_AFTER_CALLS + 216)
%define MC_STDERR_TRUNC   (MC_AFTER_CALLS + 224)
%define MC_FRAMES_IN      (MC_AFTER_CALLS + 232)
%define MC_FRAMES_OUT     (MC_AFTER_CALLS + 240)
; Notifications and server-initiated requests, which AsmFlow records and does
; not answer, and responses to requests nobody made — which mean the session is
; not what AsmFlow believes it to be.
%define MC_NOTIFICATIONS  (MC_AFTER_CALLS + 272)
%define MC_UNMATCHED      (MC_AFTER_CALLS + 280)

; The two ceilings this child's pipes are read under, copied from the snapshot
; when the child is initialised. Copied rather than reached for through a
; back-pointer, because the framing code has a child and nothing else — and a
; limit that a reload could change mid-line would be a limit applied to half a
; message.
%define MC_FRAME_MAX      (MC_AFTER_CALLS + 248)
%define MC_STDERR_MAX     (MC_AFTER_CALLS + 256)

; Flags.
%define MC_FLAGS          (MC_AFTER_CALLS + 264)
; BORROWED backpointer to the owning supervisor.  Event callbacks receive a
; child as their context and need this only to remove a pipe from epoll before
; closing it on EOF/error; ownership remains entirely with the daemon.
%define MC_SUP            (MC_AFTER_CALLS + 288)
; Bytes at the start of the current incomplete stdout line that have already
; been checked for LF.  This makes fragmented frames linear in their total
; length instead of rescanning the entire bounded prefix after every read.
%define MC_SCAN_CURSOR    (MC_AFTER_CALLS + 296)
; The process-group id survives direct-child wait4 collection. The leader PID
; can become zero while same-group helpers still exist; teardown signals this
; saved group and clears it only after kill(2) accepted the SIGKILL or reported
; that the group was already gone.
%define MC_PGID           (MC_AFTER_CALLS + 304)
; Monotonic timestamps for restart attempts still inside the sliding window.
; MC_RESTARTS is the live element count; entries survive process lifetimes and
; are cleared only by initialisation or an explicit crash-loop reset.
%define MC_RESTART_HISTORY (MC_AFTER_CALLS + 312)
%define MC_AFTER_RESTART_HISTORY (MC_RESTART_HISTORY + AF_MCP_RESTART_HISTORY_BYTES)

; Transport-neutral server identity followed by pointers owned only by the
; Streamable-HTTP adapter. Stdio leaves the pointers NULL. An HTTP completion
; validates the generation before touching a reused fixed transfer slot.
%define MC_TRANSPORT       (MC_AFTER_RESTART_HISTORY + 0)
%define MC_ADAPTER_KIND    (MC_AFTER_RESTART_HISTORY + 8)
%define MC_ADAPTER         (MC_AFTER_RESTART_HISTORY + 16)
%define MC_GENERATION      (MC_AFTER_RESTART_HISTORY + 24)
%define MC_HTTP_POST       (MC_AFTER_RESTART_HISTORY + 32)
%define MC_HTTP_GET        (MC_AFTER_RESTART_HISTORY + 40)

; Cache identity never stores a credential. The fingerprint is a non-secret
; change detector and the cache remains server-local even for public scope.
%define MC_CACHE_SCOPE     (MC_AFTER_RESTART_HISTORY + 48)
%define MC_CACHE_AUTH_HASH (MC_AFTER_RESTART_HISTORY + 56)
%define MC_CACHE_KEY_HASH  (MC_AFTER_RESTART_HISTORY + 64)
%define MC_SIZE            (MC_AFTER_RESTART_HISTORY + 72)

%define AF_MCP_CACHE_NONE    0
%define AF_MCP_CACHE_PUBLIC  1
%define AF_MCP_CACHE_PRIVATE 2
%define AF_MCP_CACHE_TTL_MAX_MS 300000

%define AF_MC_F_STDIN_OPEN   1    ; the child's stdin is still ours to write
%define AF_MC_F_REAPED       2    ; wait4 has collected this pid
%define AF_MC_F_STOPPING     4    ; a shutdown sequence is under way
%define AF_MC_F_MANUAL_STOP  8    ; an operator stopped it; do not restart
%define AF_MC_F_PROBED       16   ; era decided for this process lifetime
; A line past the frame ceiling is being discarded up to its terminator. The
; framing is newline-delimited, so a stream CAN be resynchronised from an
; oversized message — unlike HTTP framing, where the parser would no longer
; know where the next message starts.
%define AF_MC_F_DISCARDING   32
; The server closed its protocol pipe. It has finished talking, so anything
; still pending will not be answered.
%define AF_MC_F_EOF          64
; The inventory sequence has been issued for this process lifetime.
%define AF_MC_F_LISTED       128
; The current stderr line has already crossed its ceiling (or could not be
; appended).  Further bytes from that same line are dropped without counting
; the same truncation again; newline/flush clears the flag for the next line.
%define AF_MC_F_ERR_TRUNCATED 256
; A protocol/process failure is stopping the current process before spending
; restart budget.  The sweep schedules the restart only after wait4 has
; collected that process, so af_mcp_start can never race a still-live pid.
%define AF_MC_F_RESTART_AFTER_STOP 512
; SIGTERM has been sent for this shutdown.  Without this phase bit the one
; deadline field could not distinguish "grace after stdin EOF" from "force
; kill after SIGTERM".
%define AF_MC_F_TERM_SENT 1024
; An operator-requested restart bypasses the automatic restart policy and its
; backoff, but only after the old process has been reaped.
%define AF_MC_F_MANUAL_RESTART 2048
; A validated tools/list array was committed for the current inventory batch.
; This is distinct from a non-empty cache: [] is a valid successful result,
; while stale bytes from a previous refresh must not satisfy readiness.
%define AF_MC_F_TOOLS_CURRENT 4096
; At least one non-EOF process/protocol failure caused this shutdown.  EOF may
; arrive later as the cooperative child exits, so AF_MC_F_EOF alone cannot
; distinguish a clean exit from a failed session.
%define AF_MC_F_PROCESS_FAILURE 8192
; A timed-out modern discovery must not be followed by legacy initialize in
; the same process. This one-shot survives teardown, bypasses automatic
; restart policy/budget, and is consumed by the next start. It deliberately is
; not process-lifetime state: clearing that group is part of start itself.
%define AF_MC_F_LEGACY_NEXT 16384
; HTTP serialises one POST per configured server. These phase bits preserve
; the transactional inventory order without imposing that restriction on the
; stdio adapter, which may keep its three list calls in flight together.
%define AF_MC_F_HTTP_RESOURCES_ISSUED 32768
%define AF_MC_F_HTTP_PROMPTS_ISSUED   65536
%define AF_MC_F_HTTP_NOTIFY_PENDING   131072

; State that belongs to one spawned process rather than to the configured
; child.  MANUAL_STOP is deliberately absent: operator intent survives a
; process boundary until an explicit reset.
%define AF_MC_F_PROCESS_LIFETIME (AF_MC_F_STDIN_OPEN | AF_MC_F_REAPED | AF_MC_F_STOPPING | AF_MC_F_PROBED | AF_MC_F_DISCARDING | AF_MC_F_EOF | AF_MC_F_LISTED | AF_MC_F_ERR_TRUNCATED | AF_MC_F_RESTART_AFTER_STOP | AF_MC_F_TERM_SENT | AF_MC_F_MANUAL_RESTART | AF_MC_F_TOOLS_CURRENT | AF_MC_F_PROCESS_FAILURE | AF_MC_F_HTTP_RESOURCES_ISSUED | AF_MC_F_HTTP_PROMPTS_ISSUED | AF_MC_F_HTTP_NOTIFY_PENDING)

; --- af_mcp_supervisor ------------------------------------------------------
%define MS_LOOP        0
%define MS_RT          8
%define MS_COUNT       16
%define MS_TIMER_FD    24   ; drives restarts and call deadlines
%define MS_STARTED     32
%define MS_HTTP        40   ; af_mcp_http_engine, separate curl multi reactor
%define MS_CHILDREN    (MS_HTTP + HE_SIZE)
%define MS_SIZE        (MS_CHILDREN + AF_MCP_MAX_CHILDREN * MC_SIZE)

; How often the supervisor sweeps for due restarts and expired calls. The same
; reasoning as the HTTP idle sweep (ADR 0010): one timer for a property of the
; table rather than a timer per member of it.
%define AF_MCP_TICK_MS 250

; The most a restart backoff may grow, as a multiple of the configured base.
%define AF_MCP_MAX_BACKOFF 32

; The exit status a child uses when execve itself failed. Distinct from
; anything a real server would choose, so "the command could not be run" is
; distinguishable from "the server started and then exited".
%define AF_MCP_EXEC_FAILED 127

; The spawn path's file, descriptor, and process constants live in
; `include/fileio.inc`, which `src/config` needed first.

%endif ; ASMFLOW_MCP_INC
