; AsmFlow — the daemon's mutable state, in one place.
;
; ARCHITECTURE.md 2: a single long-running daemon owns every piece of mutable
; state. This structure IS that ownership, written down. Everything below the
; entry point reaches state through a pointer to it rather than through a global,
; so a test can stand up a runtime, drive it, and tear it down without the
; process carrying anything over.

%ifndef ASMFLOW_RUNTIME_INC
%define ASMFLOW_RUNTIME_INC

;   +0   config        af_config * (the published snapshot; reference held)
;   +8   db            af_db *
;   +16  loop          af_loop *
;   +24  ctl           af_ctl_server *
;   +32  started_at_ms wall clock, for uptime reporting
;   +40  started_at_ns monotonic, for the uptime that is actually computed
;   +48  ready         1 once every required dependency is satisfied
;   +56  shutting_down 1 once SIGTERM has been observed
;   +64  config_path   char * (BORROWED from argv or the arena)
;   +72  config_arena  af_arena * holding the resolved default path
;   +80  reload_count
;   +88  last_error    af_status of the most recent reload attempt
%define RT_CONFIG        0
%define RT_DB            8
%define RT_LOOP          16
%define RT_CTL           24
%define RT_STARTED_MS    32
%define RT_STARTED_NS    40
%define RT_READY         48
%define RT_SHUTTING_DOWN 56
%define RT_CONFIG_PATH   64
%define RT_CONFIG_ARENA  72
%define RT_RELOAD_COUNT  80
%define RT_LAST_ERROR    88
%define RT_SIZE          96

%endif ; ASMFLOW_RUNTIME_INC
