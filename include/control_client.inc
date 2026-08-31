; AsmFlow -- control-plane client layout shared by asmflow-tui and asmflowctl.
;
; The client owns its two af_buffer payloads and its connected descriptor.  The
; structure storage itself is caller-owned.  `af_ctl_client_close` is
; idempotent and must be called before the storage is reused.

%ifndef ASMFLOW_CONTROL_CLIENT_INC
%define ASMFLOW_CONTROL_CLIENT_INC

; Public CLI presentation modes.
%define AF_CTL_MODE_TABLE 0
%define AF_CTL_MODE_JSON  1

; Client-side bounds.  The wire ceiling is the normative one from
; include/control.inc; these bounds cover command-line material before it is
; admitted to a frame.
%define AF_CTLC_METHOD_MAX       256
%define AF_CTLC_PATH_MAX         107
; Leave room for the request envelope, the worst-case six-byte JSON escaping
; of a bounded method, and the string request id under the normative one-MiB
; NDJSON frame ceiling.  Thus every locally accepted params object can be
; framed before any socket write rather than failing after connect.
%define AF_CTLC_PARAMS_MAX       (AF_CTL_FRAME_DEFAULT_MAX - 4096)
%define AF_CTLC_READ_CHUNK       4096
%define AF_CTLC_JSON_DEPTH       64
%define AF_CTLC_JSON_ELEMENTS    10000
%define AF_CTLC_EVENT_SKIP_MAX   1024
%define AF_CTLC_ID_STORAGE       32
%define AF_CTLC_TABLE_OUTPUT_MAX (4 * 1024 * 1024)
; A local control peer must not hold an operator command or terminal cleanup
; path forever after accepting the Unix socket. Linux SO_RCVTIMEO/SO_SNDTIMEO
; use this bounded timeval; a timeout is surfaced as a normal client error.
%define AF_CTLC_IO_TIMEOUT_SEC    5

; af_ctl_client
;   +0   fd          owned connected AF_UNIX descriptor, -1 when closed
;   +8   next_id     next numeric suffix for the string request id
;   +16  last_ok     boolean from the last correlated response
;   +24  initialized buffers have been initialized
;   +32  inbox       owned af_buffer, bounded to one control frame
;   +64  outbox      owned af_buffer, bounded to one control frame
;   +96  id          current request id bytes (not NUL-terminated)
;   +128 id_len      current request id byte length
%define AF_CTLC_FD          0
%define AF_CTLC_NEXT_ID     8
%define AF_CTLC_LAST_OK     16
%define AF_CTLC_INITIALIZED 24
%define AF_CTLC_INBOX       32
%define AF_CTLC_OUTBOX      64
%define AF_CTLC_ID          96
%define AF_CTLC_ID_LEN      128
%define AF_CTLC_SIZE        144

%endif ; ASMFLOW_CONTROL_CLIENT_INC
