; AsmFlow — pure TUI presentation contracts.
;
; This include describes only caller-owned presentation memory.  None of the
; structures owns a pointer: canvas storage, model rows, cell text, stable IDs,
; and output buffers are BORROWED for the duration of one call.  The pure M10
; modules never allocate, access SQLite, open the control socket, or call
; ncurses.  `tui_run.asm` is the eventual owner of those lifetimes.

%ifndef ASMFLOW_TUI_INC
%define ASMFLOW_TUI_INC

; Hard presentation bounds.  A terminal outside these maxima is rejected
; before width*height arithmetic reaches caller-owned memory.
%define AF_TUI_MAX_COLUMNS       512
%define AF_TUI_MAX_ROWS          256
%define AF_TUI_MAX_CELLS         (AF_TUI_MAX_COLUMNS * AF_TUI_MAX_ROWS)
%define AF_TUI_TEXT_MAX_BYTES    (1024 * 1024)
%define AF_TUI_MODEL_MAX_ROWS    64
%define AF_TUI_ROW_MAX_CELLS     16
%define AF_TUI_OVERVIEW_MAX_ROUTES 8
%define AF_TUI_OVERVIEW_MAX_EVENTS 8
%define AF_TUI_SCREEN_COUNT      7
%define AF_TUI_ACTION_COUNT      22

; Canvas cells are Unicode scalar values, not encoded bytes.  This makes
; clipping happen between code points.  Canonical dump is the only place that
; encodes them as UTF-8.
%define TC_CELLS                 0
%define TC_WIDTH                 8
%define TC_HEIGHT                16
%define TC_CAPACITY              24
%define TC_SIZE                  32
%define TC_CELL_SIZE             4
; Internal second column of a width-2 scalar. Canonical dump skips this cell;
; it can never be produced by valid Unicode input.
%define AF_TUI_CELL_CONTINUATION 0xffffffff

; Responsive layout modes.
%define AF_TUI_LAYOUT_TOO_SMALL  0       ; cols < 60 or rows < 16
%define AF_TUI_LAYOUT_NARROW     1       ; cols < 80 or rows <= 20
%define AF_TUI_LAYOUT_COMPACT    2       ; 80..99 columns
%define AF_TUI_LAYOUT_STANDARD   3       ; 100..119 columns
%define AF_TUI_LAYOUT_WIDE       4       ; >= 120 columns

%define AF_TUI_LF_NAV_TABS       1
%define AF_TUI_LF_INSPECT_OVERLAY 2
%define AF_TUI_LF_DRILLDOWN      4
%define AF_TUI_LF_ENLARGE        8

; Every rectangle is {x,y,w,h}.  Rectangles never exceed cols/rows.  A zero
; width or height means the region is hidden in that mode.
%define TL_MODE                  0
%define TL_COLS                  8
%define TL_ROWS                  16
%define TL_FLAGS                 24
%define TL_TOP_X                 32
%define TL_TOP_Y                 40
%define TL_TOP_W                 48
%define TL_TOP_H                 56
%define TL_NAV_X                 64
%define TL_NAV_Y                 72
%define TL_NAV_W                 80
%define TL_NAV_H                 88
%define TL_MAIN_X                96
%define TL_MAIN_Y                104
%define TL_MAIN_W                112
%define TL_MAIN_H                120
%define TL_INSPECT_X             128
%define TL_INSPECT_Y             136
%define TL_INSPECT_W             144
%define TL_INSPECT_H             152
%define TL_EVENT_X               160
%define TL_EVENT_Y               168
%define TL_EVENT_W               176
%define TL_EVENT_H               184
%define TL_COMMAND_X             192
%define TL_COMMAND_Y             200
%define TL_COMMAND_W             208
%define TL_COMMAND_H             216
%define TL_SIZE                  224

; Column descriptor.  Widths are terminal columns.  Priority 0 is mandatory;
; 1..3 are admitted in that order and source order while they fit.
%define AF_TUI_ALIGN_LEFT        0
%define AF_TUI_ALIGN_RIGHT       1
%define TCD_ID                   0
%define TCD_PRIORITY             8
%define TCD_MIN_WIDTH            16
%define TCD_MAX_WIDTH            24
%define TCD_ALIGN                32
%define TCD_LABEL                40
%define TCD_LABEL_LEN            48
%define TCD_SIZE                 56

%define TCF_MASK                 0
%define TCF_WIDTH                8
%define TCF_SIZE                 16

; Stable screen identifiers also match direct-navigation keys 1..7.
%define AF_TUI_SCREEN_OVERVIEW   1
%define AF_TUI_SCREEN_PROVIDERS  2
%define AF_TUI_SCREEN_ROUTES     3
%define AF_TUI_SCREEN_REQUESTS   4
%define AF_TUI_SCREEN_MCP        5
%define AF_TUI_SCREEN_LOGS       6
%define AF_TUI_SCREEN_SETTINGS   7

%define TSD_ID                   0
%define TSD_KEY                  8
%define TSD_TITLE                16
%define TSD_TITLE_LEN            24
%define TSD_COLUMNS              32
%define TSD_COLUMN_COUNT         40
%define TSD_SIZE                 48

; Required non-colour status vocabulary.
%define AF_TUI_STATUS_OK         0
%define AF_TUI_STATUS_WARN       1
%define AF_TUI_STATUS_OPEN       2
%define AF_TUI_STATUS_FAIL       3
%define AF_TUI_STATUS_OFF        4
%define AF_TUI_STATUS_RUN        5
%define AF_TUI_STATUS_COUNT      6

; Generic, fixed-size view model consumed by af_tui_render_screen.  Text and
; row arrays are BORROWED and capped before dereference.  A NULL model renders
; the built-in disconnected diagnostic state.
%define AF_TUI_CONN_CONNECTED    0
%define AF_TUI_CONN_STALE        1
%define AF_TUI_CONN_DISCONNECTED 2

%define TT_PTR                   0
%define TT_LEN                   8
%define TT_SIZE                  16

%define TR_ID_PTR                0
%define TR_ID_LEN                8
%define TR_CELLS                 16      ; BORROWED TUI_TEXT[TR_CELL_COUNT]
%define TR_CELL_COUNT            24
%define TR_SIZE                  32

%define TM_CONNECTION            0
%define TM_REVISION              8
%define TM_ACTIVE_REQUESTS       16
%define TM_MCP_RUNNING           24
%define TM_MCP_TOTAL             32
%define TM_UTC_PTR               40
%define TM_UTC_LEN               48
%define TM_ROWS                  56      ; BORROWED TUI_ROW[TM_ROW_COUNT]
%define TM_ROW_COUNT             64
%define TM_DETAIL_TITLE_PTR      72
%define TM_DETAIL_TITLE_LEN      80
%define TM_DETAIL_BODY_PTR       88
%define TM_DETAIL_BODY_LEN       96
%define TM_EVENT_PTR             104
%define TM_EVENT_LEN             112
%define TM_SELECTED_INDEX        120     ; UINT64_MAX means no focused row
%define TM_OVERVIEW              128     ; optional BORROWED TUI_OVERVIEW *
%define TM_FLAGS                 136
%define TM_SIZE                  144

; Dedicated Overview view model.  The screen is a summary/routes/events
; composition rather than a generic table, so making the mapping explicit is
; safer than overloading magic row positions.
%define TO_GATEWAY_STATUS        0
%define TO_PROVIDER_OK           8
%define TO_PROVIDER_WARN         16
%define TO_PROVIDER_OPEN         24
%define TO_PROVIDER_OFF          32
%define TO_MCP_OK                40
%define TO_MCP_RUN               48
%define TO_MCP_FAIL              56
%define TO_MCP_OFF               64
%define TO_ROUTES                72      ; BORROWED TUI_OVERVIEW_ROUTE[]
%define TO_ROUTE_COUNT           80
%define TO_EVENTS                88      ; BORROWED TUI_OVERVIEW_EVENT[]
%define TO_EVENT_COUNT           96
%define TO_SIZE                  104

%define TOR_STATUS               0
%define TOR_ALIAS_PTR            8
%define TOR_ALIAS_LEN            16
%define TOR_POLICY_PTR           24
%define TOR_POLICY_LEN           32
%define TOR_TARGETS              40
%define TOR_ELIGIBLE             48
%define TOR_ACTIVE               56
%define TOR_LAST_PTR             64
%define TOR_LAST_LEN             72
%define TOR_SIZE                 80

%define TOE_STATUS               0
%define TOE_TEXT_PTR             8
%define TOE_TEXT_LEN             16
%define TOE_SIZE                 24

; Stable-ID-only row view used by selection resolution.  The byte span is
; BORROWED and may contain no terminator.
%define TID_PTR                  0
%define TID_LEN                  8
%define TID_SIZE                 16

; Canonical key event.  The curses adapter passes ASCII unchanged and maps its
; KEY_* values to the constants below (the common ncurses ABI values are also
; accepted directly by af_tui_keymap).
%define AF_TUI_KEY_DOWN          258
%define AF_TUI_KEY_UP            259
%define AF_TUI_KEY_LEFT          260
%define AF_TUI_KEY_RIGHT         261
%define AF_TUI_KEY_ENTER         343
%define AF_TUI_KEY_BTAB          353

%define AF_TUI_CMD_SCREEN        1
%define AF_TUI_CMD_FOCUS_NEXT    2
%define AF_TUI_CMD_FOCUS_PREV    3
%define AF_TUI_CMD_ROW_NEXT      4
%define AF_TUI_CMD_ROW_PREV      5
%define AF_TUI_CMD_OPEN          6
%define AF_TUI_CMD_BACK          7
%define AF_TUI_CMD_FILTER        8
%define AF_TUI_CMD_PALETTE       9
%define AF_TUI_CMD_HELP          10
%define AF_TUI_CMD_REFRESH       11
%define AF_TUI_CMD_TOGGLE_SELECT 12
%define AF_TUI_CMD_QUIT          13

%define TKE_COMMAND              0
%define TKE_ARGUMENT             8
%define TKE_SIZE                 16

; Action risk and availability.  Descriptors with risk >= 2 are constructed
; with AF_TUI_AF_CONFIRM; Level 4 descriptors never have AF_TUI_AF_AVAILABLE.
%define AF_TUI_RISK_0            0
%define AF_TUI_RISK_1            1
%define AF_TUI_RISK_2            2
%define AF_TUI_RISK_3            3
%define AF_TUI_RISK_4            4
%define AF_TUI_AF_CONFIRM        1
%define AF_TUI_AF_AVAILABLE      2

%define AF_TUI_ACTION_VIEW       1
%define AF_TUI_ACTION_FILTER     2
%define AF_TUI_ACTION_SORT       3
%define AF_TUI_ACTION_OPEN       4
%define AF_TUI_ACTION_HELP       5
%define AF_TUI_ACTION_QUIT       6
%define AF_TUI_ACTION_REFRESH    7
%define AF_TUI_ACTION_PROVIDER_PROBE 8
%define AF_TUI_ACTION_MCP_DISCOVER 9
%define AF_TUI_ACTION_DIAGNOSTICS_EXPORT 10
%define AF_TUI_ACTION_PROVIDER_ENABLE 11
%define AF_TUI_ACTION_PROVIDER_DISABLE 12
%define AF_TUI_ACTION_MCP_START  13
%define AF_TUI_ACTION_MCP_STOP   14
%define AF_TUI_ACTION_MCP_RESTART 15
%define AF_TUI_ACTION_MCP_RESET_CRASH_LOOP 16
%define AF_TUI_ACTION_CONFIG_RELOAD 17
%define AF_TUI_ACTION_MCP_TOOL_TEST 18
%define AF_TUI_ACTION_ROUTE_MUTATE 19
%define AF_TUI_ACTION_LISTENER_NONLOOPBACK 20
%define AF_TUI_ACTION_MULTI_SERVER_STOP 21
%define AF_TUI_ACTION_DB_RESET   22

%define TAD_ID                   0
%define TAD_RISK                 8
%define TAD_FLAGS                16
%define TAD_LABEL                24
%define TAD_LABEL_LEN            32
%define TAD_METHOD               40      ; optional static control method
%define TAD_METHOD_LEN           48
%define TAD_SIZE                 56

%endif ; ASMFLOW_TUI_INC
