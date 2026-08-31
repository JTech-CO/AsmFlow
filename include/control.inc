; AsmFlow — control-plane protocol layout.
;
; docs/API_CONTRACT.md 9: a Unix stream socket at mode 0600, UTF-8 NDJSON, one
; object per line, at most 1 MiB per frame, requests and responses correlated by
; `id`, and server events carrying `event` with no `id`.

%ifndef ASMFLOW_CONTROL_INC
%define ASMFLOW_CONTROL_INC

%define AF_CTL_FRAME_DEFAULT_MAX (1024 * 1024)
%define AF_CTL_ID_MAX            128
%define AF_CTL_MAX_CLIENTS       64
%define AF_CTL_PROTOCOL_VERSION  1

; Pagination (docs/API_CONTRACT.md 11).
%define AF_CTL_LIMIT_DEFAULT 100
%define AF_CTL_LIMIT_MAX     1000

; af_ctl_conn — one accepted client.
;
;   +0   fd            -1 when the slot is free
;   +8   server        af_ctl_server * (BORROWED)
;   +16  inbox         af_buffer: bytes read but not yet framed
;   +48  outbox        af_buffer: bytes framed but not yet written
;   +80  out_cursor    how much of the outbox has already been written
;   +88  peer_uid      SO_PEERCRED, recorded for the audit trail
;   +96  peer_pid
;   +104 frames        frames handled on this connection
;   +112 closing       1 once the last response has been queued
%define CONN_FD         0
%define CONN_SERVER     8
%define CONN_INBOX      16
%define CONN_OUTBOX     48
%define CONN_OUT_CURSOR 80
%define CONN_PEER_UID   88
%define CONN_PEER_PID   96
%define CONN_FRAMES     104
%define CONN_CLOSING    112
%define CONN_SIZE       120

; af_ctl_server
;
;   +0   listen_fd
;   +8   socket_path   char * (BORROWED from the configuration snapshot)
;   +16  frame_max
;   +24  revision      bumped on every state change a client can observe
;   +32  accepted      connections accepted since startup
;   +40  rejected      connections refused because the table was full
;   +48  loop          af_loop * (BORROWED)
;   +56  rt            void *: the daemon runtime the methods read from
;   +64  conns         af_ctl_conn[AF_CTL_MAX_CLIENTS]
%define CTLS_LISTEN_FD 0
%define CTLS_PATH      8
%define CTLS_FRAME_MAX 16
%define CTLS_REVISION  24
%define CTLS_ACCEPTED  32
%define CTLS_REJECTED  40
%define CTLS_LOOP      48
%define CTLS_RT        56
%define CTLS_CONNS     64
%define CTLS_SIZE      (CTLS_CONNS + AF_CTL_MAX_CLIENTS * CONN_SIZE)

; Control error codes as they appear on the wire. Strings rather than numbers,
; because docs/API_CONTRACT.md 9 shows them that way and an operator reads them.
%define AF_CTLERR_INVALID_JSON    0
%define AF_CTLERR_FRAME_TOO_LARGE 1
%define AF_CTLERR_UNKNOWN_METHOD  2
%define AF_CTLERR_INVALID_PARAMS  3
%define AF_CTLERR_CURSOR_STALE    4
%define AF_CTLERR_STATE           5
%define AF_CTLERR_INTERNAL        6
%define AF_CTLERR_NOT_FOUND       7
%define AF_CTLERR_UNCONFIRMED     8
%define AF_CTLERR_UNSUPPORTED     9
%define AF_CTLERR_COUNT           10

%endif ; ASMFLOW_CONTROL_INC
