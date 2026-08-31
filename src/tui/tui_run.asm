; AsmFlow -- asmflow-tui runtime and terminal owner.
;
; This module is the only TUI component that owns a control connection or
; changes terminal state. Both interactive output and --dump-layout pass
; through the same bounded canvas/model renderer. The dump path never calls
; ncurses. The interactive path blocks termination signals before initscr(),
; consumes them through signalfd, and has one ordered cleanup path.

        bits 64
        default rel

%include "asmflow.inc"
%include "control.inc"
%include "control_client.inc"
%include "fileio.inc"
%include "json.inc"
%include "tui.inc"

        extern getenv
        extern setlocale

        extern af_buf_init
        extern af_buf_free
        extern af_buf_clear
        extern af_buf_append
        extern af_buf_append_byte
        extern af_buf_append_u64
        extern af_buf_data
        extern af_buf_len
        extern af_mem_copy
        extern af_mem_eq
        extern af_write_all
        extern af_sys_getuid
        extern af_sys_close
        extern af_sys_recvfrom

        extern af_ctlc_cstrnlen
        extern af_ctl_client_init
        extern af_ctl_client_close
        extern af_ctl_client_call
        extern af_ctl_client_last_ok
        extern af_ctl_client_fd

        extern af_json_parse
        extern af_json_doc_root
        extern af_json_doc_free
        extern af_json_type
        extern af_json_get_bool
        extern af_json_get_integer
        extern af_json_get_object
        extern af_jw_init
        extern af_jw_begin_object
        extern af_jw_end_object
        extern af_jw_member_string_n
        extern af_jw_finish

        extern af_tui_canvas_init
        extern af_tui_canvas_dump
        extern af_tui_render_screen
        extern af_tui_sanitize_utf8
        extern af_tui_keymap
        extern af_tui_action_descriptor
        extern af_tui_action_requires_confirmation
        extern af_tui_action_available
        extern af_tui_model_reset
        extern af_tui_model_set_frame
        extern af_tui_model_build
        extern af_tui_model_select_next
        extern af_tui_model_select_prev
        extern af_tui_model_selected_id

        extern af_signal_mask_build
        extern af_signals_block
        extern af_signals_restore
        extern af_signalfd_open
        extern af_signalfd_next
        extern af_signal_is_termination

        extern af_ncc_getmaxyx
        extern af_ncc_err

        extern initscr
        extern cbreak
        extern nocbreak
        extern noecho
        extern echo
        extern keypad
        extern wtimeout
        extern wgetch
        extern werase
        extern wmove
        extern waddnstr
        extern wrefresh
        extern curs_set
        extern set_escdelay
        extern endwin

%define AF_FD_STDOUT  1
%define AF_FD_STDERR  2
%define LC_ALL        6

%define TUI_FLAG_MONO 1
%define TUI_FLAG_DUMP 2

%define TUI_BUFFER_SIZE 32
%define TUI_RESPONSE_COUNT 9
%define TUI_STAGE_COUNT 4
%define TUI_R_VERSION   (0 * TUI_BUFFER_SIZE)
%define TUI_R_SNAPSHOT  (1 * TUI_BUFFER_SIZE)
%define TUI_R_PROVIDERS (2 * TUI_BUFFER_SIZE)
%define TUI_R_ROUTES    (3 * TUI_BUFFER_SIZE)
%define TUI_R_REQUESTS  (4 * TUI_BUFFER_SIZE)
%define TUI_R_MCP       (5 * TUI_BUFFER_SIZE)
%define TUI_R_LOGS      (6 * TUI_BUFFER_SIZE)
%define TUI_R_CONFIG    (7 * TUI_BUFFER_SIZE)
%define TUI_R_ACTION    (8 * TUI_BUFFER_SIZE)
%define TUI_S_PRIMARY   (0 * TUI_BUFFER_SIZE)
%define TUI_S_SECONDARY (1 * TUI_BUFFER_SIZE)
%define TUI_S_TERTIARY  (2 * TUI_BUFFER_SIZE)
%define TUI_S_QUATERNARY (3 * TUI_BUFFER_SIZE)

; Kept numerically stable in include/tui_model.inc. Local definitions avoid
; making runtime assembly depend on the model's private storage layout.
%define TUI_MODEL_FRAME_VERSION   1
%define TUI_MODEL_FRAME_SNAPSHOT  2
%define TUI_MODEL_FRAME_PROVIDERS 3
%define TUI_MODEL_FRAME_ROUTES    4
%define TUI_MODEL_FRAME_REQUESTS  5
%define TUI_MODEL_FRAME_MCP       6
%define TUI_MODEL_FRAME_LOGS      7
%define TUI_MODEL_FRAME_CONFIG    8

%define TUI_DUMP_CAPACITY ((AF_TUI_MAX_CELLS * 4) + AF_TUI_MAX_ROWS)
%define TUI_COMMAND_CAPACITY 64
%define TUI_GETCH_TIMEOUT_MS 150
%define TUI_STABLE_ID_MAX 128
%define TUI_PARAMS_MAX 512
%define TUI_OVERLAY_ID_CAP (TUI_STABLE_ID_MAX * 6)
%define TUI_OVERLAY_MAX 1024
%define TUI_SAVED_SELECTION_COUNT 2
%define MSG_PEEK 2
%define MSG_DONTWAIT 0x40

        section .rodata

tui_env_xdg: db "XDG_RUNTIME_DIR", 0
tui_locale_from_environment: db 0
tui_path_prefix: db "/run/user/"
tui_path_prefix_len equ $ - tui_path_prefix
tui_path_suffix: db "/asmflow/control.sock"
tui_path_suffix_len equ $ - tui_path_suffix
tui_path_suffix_no_slash: db "asmflow/control.sock"
tui_path_suffix_no_slash_len equ $ - tui_path_suffix_no_slash

tui_method_version: db "system.version"
tui_method_version_len equ $ - tui_method_version
tui_method_snapshot: db "system.snapshot"
tui_method_snapshot_len equ $ - tui_method_snapshot
tui_method_providers: db "providers.list"
tui_method_providers_len equ $ - tui_method_providers
tui_method_provider_get: db "providers.get"
tui_method_provider_get_len equ $ - tui_method_provider_get
tui_method_routes: db "routes.list"
tui_method_routes_len equ $ - tui_method_routes
tui_method_requests: db "requests.list"
tui_method_requests_len equ $ - tui_method_requests
tui_method_mcp: db "mcp.list"
tui_method_mcp_len equ $ - tui_method_mcp
tui_method_logs: db "logs.tail"
tui_method_logs_len equ $ - tui_method_logs
tui_method_config: db "config.current"
tui_method_config_len equ $ - tui_method_config
tui_method_mcp_restart: db "mcp.restart"
tui_method_mcp_restart_len equ $ - tui_method_mcp_restart

tui_key_provider_id: db "provider_id", 0
tui_key_server_id: db "server_id", 0

tui_k_ok: db "ok", 0
tui_k_result: db "result", 0
tui_k_protocol_version: db "protocol_version", 0

tui_command_restart: db "mcp-restart"
tui_command_restart_len equ $ - tui_command_restart

tui_overlay_confirm_prefix: db "CONFIRM  Restart MCP server "
tui_overlay_confirm_prefix_len equ $ - tui_overlay_confirm_prefix
tui_overlay_confirm_suffix: db "?  Enter confirm  Esc cancel"
tui_overlay_confirm_suffix_len equ $ - tui_overlay_confirm_suffix
tui_overlay_help:
        db "HELP  1..7 screens  j/k rows  r refresh  : commands  Esc close  q quit"
tui_overlay_help_len equ $ - tui_overlay_help
tui_overlay_command:
        db "COMMAND  mcp-restart  Enter submit  Esc cancel"
tui_overlay_command_len equ $ - tui_overlay_command

tui_err_connect:
        db "asmflow-tui: could not connect to the daemon control socket.", 10
tui_err_connect_len equ $ - tui_err_connect
tui_err_protocol:
        db "asmflow-tui: daemon protocol_version is not supported.", 10
tui_err_protocol_len equ $ - tui_err_protocol
tui_err_runtime:
        db "asmflow-tui: console rendering failed.", 10
tui_err_runtime_len equ $ - tui_err_runtime

        section .bss
        align 16
tui_client: resb AF_CTLC_SIZE
tui_path_buffer: resb TUI_BUFFER_SIZE
tui_params_buffer: resb TUI_BUFFER_SIZE
tui_overlay_buffer: resb TUI_BUFFER_SIZE
tui_responses: resb (TUI_RESPONSE_COUNT * TUI_BUFFER_SIZE)
tui_staged_responses: resb (TUI_STAGE_COUNT * TUI_BUFFER_SIZE)
tui_canvas: resb TC_SIZE
tui_cells: resd AF_TUI_MAX_CELLS
tui_dump_buffer: resb TUI_DUMP_CAPACITY
tui_dump_len: resq 1
tui_socket_path: resq 1
tui_current_screen: resq 1
tui_connection_state: resq 1
tui_width: resq 1
tui_height: resq 1
tui_window: resq 1
tui_client_ready: resq 1
tui_curses_ready: resq 1
tui_signals_blocked: resq 1
tui_signal_fd: resq 1
tui_signal_mask: resq 1
tui_previous_mask: resq 1
tui_previous_cursor: resq 1
tui_command_active: resq 1
tui_command_len: resq 1
tui_command_buffer: resb TUI_COMMAND_CAPACITY
tui_overlay_id: resb TUI_OVERLAY_ID_CAP
tui_overlay_id_len: resq 1
tui_saved_selections: resb (TUI_SAVED_SELECTION_COUNT * TUI_STABLE_ID_MAX)
tui_saved_selection_lens: resq TUI_SAVED_SELECTION_COUNT
tui_confirmation: resq 1
tui_help_visible: resq 1

        section .text

; ---------------------------------------------------------------------------
; Bounded buffer ownership.
; ---------------------------------------------------------------------------
_af_tuir_buffers_init:
        AF_ENTER 0
        lea     rdi, [tui_path_buffer]
        mov     rsi, AF_CTLC_PATH_MAX + 1
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rdi, [tui_params_buffer]
        mov     rsi, TUI_PARAMS_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rdi, [tui_overlay_buffer]
        mov     rsi, TUI_OVERLAY_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rbx, [tui_responses]
        xor     r12d, r12d
.loop:
        cmp     r12, TUI_RESPONSE_COUNT
        jae     .stages
        mov     rax, r12
        imul    rax, TUI_BUFFER_SIZE
        lea     rdi, [rbx + rax]
        mov     rsi, AF_CTL_FRAME_DEFAULT_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        inc     r12
        jmp     .loop
.stages:
        lea     rbx, [tui_staged_responses]
        xor     r12d, r12d
.stage_loop:
        cmp     r12, TUI_STAGE_COUNT
        jae     .ok
        mov     rax, r12
        imul    rax, TUI_BUFFER_SIZE
        lea     rdi, [rbx + rax]
        mov     rsi, AF_CTL_FRAME_DEFAULT_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        inc     r12
        jmp     .stage_loop
.ok:
        xor     eax, eax
.done:
        AF_LEAVE

_af_tuir_buffers_free:
        AF_ENTER 0
        lea     rbx, [tui_staged_responses]
        xor     r12d, r12d
.stage_loop:
        cmp     r12, TUI_STAGE_COUNT
        jae     .responses
        mov     rax, r12
        imul    rax, TUI_BUFFER_SIZE
        lea     rdi, [rbx + rax]
        call    af_buf_free
        inc     r12
        jmp     .stage_loop
.responses:
        lea     rbx, [tui_responses]
        xor     r12d, r12d
.loop:
        cmp     r12, TUI_RESPONSE_COUNT
        jae     .path
        mov     rax, r12
        imul    rax, TUI_BUFFER_SIZE
        lea     rdi, [rbx + rax]
        call    af_buf_free
        inc     r12
        jmp     .loop
.path:
        lea     rdi, [tui_overlay_buffer]
        call    af_buf_free
        lea     rdi, [tui_params_buffer]
        call    af_buf_free
        lea     rdi, [tui_path_buffer]
        call    af_buf_free
        AF_LEAVE

; XDG_RUNTIME_DIR/asmflow/control.sock, with /run/user/<uid> fallback.
_af_tuir_default_path:
        AF_ENTER 32
        lea     rbx, [tui_path_buffer]
        mov     rdi, rbx
        call    af_buf_clear
        lea     rdi, [tui_env_xdg]
        AF_CCALL getenv
        mov     r12, rax
        test    r12, r12
        jz      .fallback
        cmp     byte [r12], '/'
        jne     .fallback
        mov     rdi, r12
        mov     rsi, AF_CTLC_PATH_MAX
        lea     rdx, [rsp]
        call    af_ctlc_cstrnlen
        test    rax, rax
        js      .done
        cmp     qword [rsp], 0
        je      .fallback
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, [rsp]
        call    af_buf_append
        test    rax, rax
        js      .done
        mov     rcx, [rsp]
        cmp     byte [r12 + rcx - 1], '/'
        je      .no_slash
        mov     rdi, rbx
        lea     rsi, [tui_path_suffix]
        mov     rdx, tui_path_suffix_len
        call    af_buf_append
        jmp     .terminate
.no_slash:
        mov     rdi, rbx
        lea     rsi, [tui_path_suffix_no_slash]
        mov     rdx, tui_path_suffix_no_slash_len
        call    af_buf_append
        jmp     .terminate
.fallback:
        mov     rdi, rbx
        lea     rsi, [tui_path_prefix]
        mov     rdx, tui_path_prefix_len
        call    af_buf_append
        test    rax, rax
        js      .done
        call    af_sys_getuid
        mov     rsi, rax
        mov     rdi, rbx
        call    af_buf_append_u64
        test    rax, rax
        js      .done
        mov     rdi, rbx
        lea     rsi, [tui_path_suffix]
        mov     rdx, tui_path_suffix_len
        call    af_buf_append
.terminate:
        test    rax, rax
        js      .done
        mov     rdi, rbx
        xor     esi, esi
        call    af_buf_append_byte
        test    rax, rax
        js      .done
        mov     rdi, rbx
        call    af_buf_data
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; _af_tuir_call(kind, method, method_len, params, params_len, response_buf)
;   -> af_status. kind==0 leaves the model untouched.
; ---------------------------------------------------------------------------
_af_tuir_call:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8
        mov     [rsp], r9
        lea     rdi, [tui_client]
        mov     rsi, r12
        mov     rdx, r13
        mov     rcx, r14
        mov     r8, r15
        mov     r9, [rsp]
        call    af_ctl_client_call
        test    rax, rax
        js      .done
        test    rbx, rbx
        jz      .ok
        mov     rdi, [rsp]
        call    af_buf_data
        mov     [rsp + 8], rax
        mov     rdi, [rsp]
        call    af_buf_len
        mov     rdx, rax
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        call    af_tui_model_set_frame
        jmp     .done
.ok:
        xor     eax, eax
.done:
        AF_LEAVE

; Strictly validate the negotiated control protocol before using a snapshot.
_af_tuir_validate_version:
        AF_ENTER 128
        lea     rdi, [tui_client]
        call    af_ctl_client_last_ok
        cmp     rax, 1
        jne     .invalid
        lea     rdi, [tui_responses + TUI_R_VERSION]
        call    af_buf_data
        mov     rbx, rax
        lea     rdi, [tui_responses + TUI_R_VERSION]
        call    af_buf_len
        mov     r12, rax
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
        js      .invalid
        lea     rdi, [rsp + 32]
        call    af_json_doc_root
        mov     [rsp + 64], rax
        mov     rdi, rax
        call    af_json_type
        cmp     rax, AF_JSON_OBJECT
        jne     .free_invalid
        mov     rdi, [rsp + 64]
        lea     rsi, [tui_k_ok]
        lea     rdx, [rsp + 80]
        call    af_json_get_bool
        test    rax, rax
        js      .free_invalid
        cmp     qword [rsp + 80], 1
        jne     .free_invalid
        mov     rdi, [rsp + 64]
        lea     rsi, [tui_k_result]
        lea     rdx, [rsp + 72]
        call    af_json_get_object
        test    rax, rax
        js      .free_invalid
        mov     rdi, [rsp + 72]
        lea     rsi, [tui_k_protocol_version]
        lea     rdx, [rsp + 88]
        call    af_json_get_integer
        test    rax, rax
        js      .free_invalid
        cmp     qword [rsp + 88], AF_CTL_PROTOCOL_VERSION
        jne     .free_invalid
        xor     r12d, r12d
        jmp     .free
.free_invalid:
        mov     r12, AF_E_INVALID
.free:
        lea     rdi, [rsp + 32]
        call    af_json_doc_free
        mov     rax, r12
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

%macro TUI_BOOT_CALL 4
        mov     edi, %1
        lea     rsi, [%2]
        mov     edx, %3
        xor     ecx, ecx
        xor     r8d, r8d
        lea     r9, [tui_responses + %4]
        call    _af_tuir_call
        test    rax, rax
        js      .done
%endmacro

_af_tuir_bootstrap:
        AF_ENTER 0
        call    af_tui_model_reset
        TUI_BOOT_CALL TUI_MODEL_FRAME_VERSION, tui_method_version, tui_method_version_len, TUI_R_VERSION
        call    _af_tuir_validate_version
        test    rax, rax
        js      .done
        ; Snapshot is intentionally first after version: it publishes the
        ; revision to which all remaining read views are related.
        TUI_BOOT_CALL TUI_MODEL_FRAME_SNAPSHOT, tui_method_snapshot, tui_method_snapshot_len, TUI_R_SNAPSHOT
        TUI_BOOT_CALL TUI_MODEL_FRAME_PROVIDERS, tui_method_providers, tui_method_providers_len, TUI_R_PROVIDERS
        TUI_BOOT_CALL TUI_MODEL_FRAME_ROUTES, tui_method_routes, tui_method_routes_len, TUI_R_ROUTES
        TUI_BOOT_CALL TUI_MODEL_FRAME_REQUESTS, tui_method_requests, tui_method_requests_len, TUI_R_REQUESTS
        TUI_BOOT_CALL TUI_MODEL_FRAME_MCP, tui_method_mcp, tui_method_mcp_len, TUI_R_MCP
        TUI_BOOT_CALL TUI_MODEL_FRAME_LOGS, tui_method_logs, tui_method_logs_len, TUI_R_LOGS
        TUI_BOOT_CALL TUI_MODEL_FRAME_CONFIG, tui_method_config, tui_method_config_len, TUI_R_CONFIG
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; Shared pure renderer. On success tui_dump_buffer contains a complete
; canonical UTF-8 canvas and tui_dump_len records its exact byte length.
; ---------------------------------------------------------------------------
_af_tuir_render:
        AF_ENTER 0
        lea     rdi, [tui_canvas]
        lea     rsi, [tui_cells]
        mov     rdx, AF_TUI_MAX_CELLS
        mov     rcx, [tui_width]
        mov     r8, [tui_height]
        call    af_tui_canvas_init
        test    rax, rax
        js      .done
        mov     rdi, [tui_current_screen]
        mov     rsi, [tui_connection_state]
        call    af_tui_model_build
        mov     rdx, rax
        lea     rdi, [tui_canvas]
        mov     rsi, [tui_current_screen]
        call    af_tui_render_screen
        test    rax, rax
        js      .done
        lea     rdi, [tui_canvas]
        xor     esi, esi
        xor     edx, edx
        lea     rcx, [tui_dump_len]
        call    af_tui_canvas_dump
        test    rax, rax
        js      .done
        cmp     qword [tui_dump_len], TUI_DUMP_CAPACITY
        ja      .limit
        lea     rdi, [tui_canvas]
        lea     rsi, [tui_dump_buffer]
        mov     rdx, TUI_DUMP_CAPACITY
        lea     rcx, [tui_dump_len]
        call    af_tui_canvas_dump
.done:
        AF_LEAVE
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

_af_tuir_dump_stdout:
        AF_ENTER 0
        call    _af_tuir_render
        test    rax, rax
        js      .done
        mov     edi, AF_FD_STDOUT
        lea     rsi, [tui_dump_buffer]
        mov     rdx, [tui_dump_len]
        call    af_write_all
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; Terminal setup/restore. Restore order is shared by q, SIGINT,
; disconnect+quit, and every initialization failure after initscr.
; ---------------------------------------------------------------------------
_af_tuir_terminal_init:
        AF_ENTER 0
        lea     rdi, [tui_signal_mask]
        call    af_signal_mask_build
        lea     rdi, [tui_signal_mask]
        lea     rsi, [tui_previous_mask]
        call    af_signals_block
        test    rax, rax
        js      .done
        mov     qword [tui_signals_blocked], 1
        lea     rdi, [tui_signal_mask]
        lea     rsi, [tui_signal_fd]
        call    af_signalfd_open
        test    rax, rax
        js      .failed
        AF_CCALL initscr
        test    rax, rax
        jz      .failed
        mov     [tui_window], rax
        mov     qword [tui_curses_ready], 1
        AF_CCALL cbreak
        cmp     eax, -1
        je      .failed
        AF_CCALL noecho
        cmp     eax, -1
        je      .failed
        mov     rdi, [tui_window]
        mov     esi, 1
        AF_CCALL keypad
        cmp     eax, -1
        je      .failed
        mov     rdi, [tui_window]
        mov     esi, TUI_GETCH_TIMEOUT_MS
        AF_CCALL wtimeout
        mov     edi, 25
        AF_CCALL set_escdelay
        xor     edi, edi
        AF_CCALL curs_set
        movsxd  rax, eax
        mov     [tui_previous_cursor], rax
        xor     eax, eax
        AF_LEAVE
.failed:
        mov     r12, AF_E_INTERNAL
        call    _af_tuir_terminal_cleanup
        mov     rax, r12
.done:
        AF_LEAVE

_af_tuir_terminal_cleanup:
        AF_ENTER 0
        cmp     qword [tui_curses_ready], 0
        je      .signal_fd
        mov     rdi, [tui_previous_cursor]
        test    rdi, rdi
        js      .keypad
        AF_CCALL curs_set
.keypad:
        mov     rdi, [tui_window]
        xor     esi, esi
        AF_CCALL keypad
        AF_CCALL echo
        AF_CCALL nocbreak
        AF_CCALL endwin
        mov     qword [tui_curses_ready], 0
        mov     qword [tui_window], 0
.signal_fd:
        mov     rdi, [tui_signal_fd]
        cmp     rdi, 0
        jl      .signal_mask
        call    af_sys_close
        mov     qword [tui_signal_fd], -1
.signal_mask:
        cmp     qword [tui_signals_blocked], 0
        je      .done
        lea     rdi, [tui_previous_mask]
        call    af_signals_restore
        mov     qword [tui_signals_blocked], 0
.done:
        AF_LEAVE

_af_tuir_signal_pending:
        AF_ENTER 16
        mov     rdi, [tui_signal_fd]
        cmp     rdi, 0
        jl      .no
        lea     rsi, [rsp]
        call    af_signalfd_next
        test    rax, rax
        js      .no
        ; SIGHUP means reload to the daemon, but this short-lived terminal
        ; owner has no reload policy.  Because it blocked SIGHUP with the
        ; shared mask, it must consume it as a local termination request or
        ; the default terminal-hangup action is lost forever.
        cmp     qword [rsp], SIGHUP
        je      .yes
        mov     rdi, [rsp]
        call    af_signal_is_termination
        test    rax, rax
        setnz   al
        movzx   eax, al
        AF_LEAVE
.yes:
        mov     eax, 1
        AF_LEAVE
.no:
        xor     eax, eax
        AF_LEAVE

; Fixed-signature wrapper keeps the external C call aligned while making the
; bounded writer explicit to static audits.
_af_tuir_waddnstr:
        AF_ENTER 0
        AF_CCALL waddnstr
        AF_LEAVE

; Present the canonical canvas through bounded ncurses calls. Rows are
; right-trimmed before waddnstr to avoid padding into the bottom-right cell.
; Any ncurses ERR is a failed presentation and must reach interactive cleanup.
_af_tuir_present:
        AF_ENTER 64
        mov     rdi, [tui_window]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_ncc_getmaxyx
        cmp     eax, -1
        je      .invalid
        mov     rax, [rsp + 8]
        test    rax, rax
        jle     .invalid
        cmp     rax, AF_TUI_MAX_COLUMNS
        jbe     .cols
        mov     rax, AF_TUI_MAX_COLUMNS
.cols:
        mov     [tui_width], rax
        mov     rax, [rsp]
        test    rax, rax
        jle     .invalid
        cmp     rax, AF_TUI_MAX_ROWS
        jbe     .rows
        mov     rax, AF_TUI_MAX_ROWS
.rows:
        mov     [tui_height], rax
        call    _af_tuir_render
        test    rax, rax
        js      .done
        mov     rdi, [tui_window]
        AF_CCALL werase
        cmp     eax, -1
        je      .present_error
        lea     rbx, [tui_dump_buffer]
        mov     r12, [tui_dump_len]
        xor     r13d, r13d                 ; byte offset
        xor     r14d, r14d                 ; row
.line:
        cmp     r13, r12
        jae     .overlay
        cmp     r14, [tui_height]
        jae     .overlay
        mov     r15, r13
.find_lf:
        cmp     r15, r12
        jae     .line_end
        cmp     byte [rbx + r15], 10
        je      .line_end
        inc     r15
        jmp     .find_lf
.line_end:
        mov     rcx, r15
        sub     rcx, r13
.trim:
        test    rcx, rcx
        jz      .next
        lea     rax, [r13 + rcx - 1]
        cmp     byte [rbx + rax], ' '
        jne     .write
        dec     rcx
        jmp     .trim
.write:
        mov     [rsp + 16], rcx
        mov     rdi, [tui_window]
        mov     rsi, r14
        xor     edx, edx
        AF_CCALL wmove
        cmp     eax, -1
        je      .present_error
        mov     rdi, [tui_window]
        lea     rsi, [rbx + r13]
        mov     rdx, [rsp + 16]
        call    _af_tuir_waddnstr
        cmp     eax, -1
        je      .present_error
.next:
        lea     r13, [r15 + 1]
        inc     r14
        jmp     .line

.overlay:
        cmp     qword [tui_confirmation], 0
        jne     .confirm
        cmp     qword [tui_help_visible], 0
        jne     .help
        cmp     qword [tui_command_active], 0
        jne     .command
        jmp     .refresh
.confirm:
        lea     rdi, [tui_overlay_buffer]
        call    af_buf_data
        mov     r12, rax
        lea     rdi, [tui_overlay_buffer]
        call    af_buf_len
        mov     r13, rax
        jmp     .put_overlay
.help:
        lea     r12, [tui_overlay_help]
        mov     r13d, tui_overlay_help_len
        jmp     .put_overlay
.command:
        lea     r12, [tui_overlay_command]
        mov     r13d, tui_overlay_command_len
.put_overlay:
        mov     r14, [tui_height]
        cmp     r14, 3
        jb      .overlay_top
        sub     r14, 2
        jmp     .overlay_row
.overlay_top:
        xor     r14d, r14d
.overlay_row:
        mov     rax, [tui_width]
        cmp     r13, rax
        jbe     .overlay_prefix_ready
        mov     r13, rax
        ; r13 is a byte limit for waddnstr.  If it lands inside a sanitized
        ; multibyte scalar, back up to the scalar's leading byte.  Bounding by
        ; bytes is also conservative for terminal columns (wcwidth <= UTF-8
        ; byte count), so the overlay cannot wrap past the screen width.
.overlay_utf8_boundary:
        test    r13, r13
        jz      .overlay_prefix_ready
        mov     al, [r12 + r13]
        and     al, 0xc0
        cmp     al, 0x80
        jne     .overlay_prefix_ready
        dec     r13
        jmp     .overlay_utf8_boundary
.overlay_prefix_ready:
        mov     rdi, [tui_window]
        mov     rsi, r14
        xor     edx, edx
        AF_CCALL wmove
        cmp     eax, -1
        je      .present_error
        mov     rdi, [tui_window]
        mov     rsi, r12
        mov     rdx, r13
        call    _af_tuir_waddnstr
        cmp     eax, -1
        je      .present_error
.refresh:
        mov     rdi, [tui_window]
        AF_CCALL wrefresh
        cmp     eax, -1
        je      .present_error
        xor     eax, eax
.done:
        AF_LEAVE
.present_error:
        AF_LEAVE_ERR AF_E_INTERNAL
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; Focused operator actions used by the deterministic keyboard contract.
; ---------------------------------------------------------------------------
; Build {"key":"selected-id"} into the owned params buffer. The model owns
; the stable-ID bytes; the JSON writer escapes them and the 128-byte bound is
; checked before any copy/allocation.
_af_tuir_build_selected_params:
        AF_ENTER 96
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        lea     rsi, [rsp + 64]
        lea     rdx, [rsp + 72]
        call    af_tui_model_selected_id
        test    rax, rax
        js      .done
        mov     rax, [rsp + 72]
        test    rax, rax
        jz      .invalid
        cmp     rax, TUI_STABLE_ID_MAX
        ja      .limit
        cmp     qword [rsp + 64], 0
        je      .invalid
        lea     rdi, [tui_params_buffer]
        call    af_buf_clear
        lea     rdi, [rsp]
        lea     rsi, [tui_params_buffer]
        call    af_jw_init
        lea     rdi, [rsp]
        call    af_jw_begin_object
        lea     rdi, [rsp]
        mov     rsi, r12
        mov     rdx, [rsp + 64]
        mov     rcx, [rsp + 72]
        call    af_jw_member_string_n
        lea     rdi, [rsp]
        call    af_jw_end_object
        lea     rdi, [rsp]
        call    af_jw_finish
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

; Build the confirmation text from the same selected MCP stable ID that the
; mutation call will serialize. Remote/control bytes are made visible first.
_af_tuir_prepare_confirmation:
        AF_ENTER 32
        mov     edi, AF_TUI_SCREEN_MCP
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_tui_model_selected_id
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .invalid
        cmp     rax, TUI_STABLE_ID_MAX
        ja      .limit
        cmp     qword [rsp], 0
        je      .invalid
        mov     rdi, [rsp]
        mov     rsi, [rsp + 8]
        lea     rdx, [tui_overlay_id]
        mov     rcx, TUI_OVERLAY_ID_CAP
        lea     r8, [tui_overlay_id_len]
        call    af_tui_sanitize_utf8
        test    rax, rax
        js      .done
        lea     rdi, [tui_overlay_buffer]
        call    af_buf_clear
        lea     rdi, [tui_overlay_buffer]
        lea     rsi, [tui_overlay_confirm_prefix]
        mov     rdx, tui_overlay_confirm_prefix_len
        call    af_buf_append
        test    rax, rax
        js      .done
        lea     rdi, [tui_overlay_buffer]
        lea     rsi, [tui_overlay_id]
        mov     rdx, [tui_overlay_id_len]
        call    af_buf_append
        test    rax, rax
        js      .done
        lea     rdi, [tui_overlay_buffer]
        lea     rsi, [tui_overlay_confirm_suffix]
        mov     rdx, tui_overlay_confirm_suffix_len
        call    af_buf_append
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.limit:
        AF_LEAVE_ERR AF_E_LIMIT

_af_tuir_provider_get:
        AF_ENTER 0
        cmp     qword [tui_connection_state], AF_TUI_CONN_CONNECTED
        jne     .state
        mov     edi, AF_TUI_SCREEN_PROVIDERS
        lea     rsi, [tui_key_provider_id]
        call    _af_tuir_build_selected_params
        test    rax, rax
        js      .done
        lea     rdi, [tui_params_buffer]
        call    af_buf_data
        mov     r12, rax
        lea     rdi, [tui_params_buffer]
        call    af_buf_len
        mov     r13, rax
        xor     edi, edi
        lea     rsi, [tui_method_provider_get]
        mov     edx, tui_method_provider_get_len
        mov     rcx, r12
        mov     r8, r13
        lea     r9, [tui_responses + TUI_R_ACTION]
        call    _af_tuir_call
.done:
        AF_LEAVE
.state:
        AF_LEAVE_ERR AF_E_CTL_STATE

; Apply one already-correlated staged response to the model without touching
; its buffer ownership. Both arguments are BORROWED for the call.
_af_tuir_apply_staged_frame:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, r12
        call    af_buf_data
        mov     [rsp], rax
        mov     rdi, r12
        call    af_buf_len
        mov     rdx, rax
        mov     rdi, rbx
        mov     rsi, [rsp]
        call    af_tui_model_set_frame
        AF_LEAVE

; Swap two owned af_buffer payload descriptors. No allocation or copy can fail,
; so this is the transaction commit point after every staged frame validates.
_af_tuir_swap_buffers:
        mov     rax, [rdi]
        mov     rcx, [rsi]
        mov     [rdi], rcx
        mov     [rsi], rax
        mov     rax, [rdi + 8]
        mov     rcx, [rsi + 8]
        mov     [rdi + 8], rcx
        mov     [rsi + 8], rax
        mov     rax, [rdi + 16]
        mov     rcx, [rsi + 16]
        mov     [rdi + 16], rcx
        mov     [rsi + 16], rax
        mov     rax, [rdi + 24]
        mov     rcx, [rsi + 24]
        mov     [rdi + 24], rcx
        mov     [rsi + 24], rax
        ret

; Save/restore one screen''s stable ID around speculative list-frame applies.
; rdi is the screen ID and rsi is a caller-assigned save slot. The model owns
; the source bytes; this runtime owns the two bounded provider/route copies.
_af_tuir_save_selection:
        AF_ENTER 16
        cmp     rsi, TUI_SAVED_SELECTION_COUNT
        jae     .invalid
        mov     rbx, rdi
        mov     r12, rsi
        lea     rax, [tui_saved_selection_lens]
        mov     qword [rax + r12 * 8], 0
        mov     rdi, rbx
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_tui_model_selected_id
        cmp     rax, AF_E_NOTFOUND
        je      .ok
        test    rax, rax
        js      .done
        mov     rax, [rsp + 8]
        cmp     rax, TUI_STABLE_ID_MAX
        ja      .limit
        mov     rdi, r12
        imul    rdi, TUI_STABLE_ID_MAX
        lea     rcx, [tui_saved_selections]
        add     rdi, rcx
        mov     rsi, [rsp]
        mov     rdx, rax
        call    af_mem_copy
        mov     rax, [rsp + 8]
        lea     rcx, [tui_saved_selection_lens]
        mov     [rcx + r12 * 8], rax
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

_af_tuir_restore_selection:
        AF_ENTER 32
        cmp     rsi, TUI_SAVED_SELECTION_COUNT
        jae     .invalid
        mov     rbx, rdi
        mov     r12, rsi
        lea     rax, [tui_saved_selection_lens]
        mov     r13, [rax + r12 * 8]
        test    r13, r13
        jz      .ok
        mov     r14, r12
        imul    r14, TUI_STABLE_ID_MAX
        lea     rax, [tui_saved_selections]
        add     r14, rax
        xor     r15d, r15d
.find:
        cmp     r15, AF_TUI_MODEL_MAX_ROWS
        jae     .not_found
        mov     rdi, rbx
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_tui_model_selected_id
        test    rax, rax
        js      .advance
        cmp     qword [rsp + 8], r13
        jne     .advance
        mov     rdi, [rsp]
        mov     rsi, r14
        mov     rdx, r13
        call    af_mem_eq
        test    rax, rax
        jnz     .ok
.advance:
        mov     rdi, rbx
        call    af_tui_model_select_next
        test    rax, rax
        js      .done
        inc     r15
        jmp     .find
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.not_found:
        AF_LEAVE_ERR AF_E_NOTFOUND
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

_af_tuir_provider_refresh:
        AF_ENTER 0
        cmp     qword [tui_connection_state], AF_TUI_CONN_CONNECTED
        jne     .state
        mov     edi, AF_TUI_SCREEN_PROVIDERS
        xor     esi, esi
        call    _af_tuir_save_selection
        test    rax, rax
        js      .done
        xor     edi, edi
        lea     rsi, [tui_method_providers]
        mov     edx, tui_method_providers_len
        xor     ecx, ecx
        xor     r8d, r8d
        lea     r9, [tui_staged_responses + TUI_S_PRIMARY]
        call    _af_tuir_call
        test    rax, rax
        js      .done
        mov     edi, TUI_MODEL_FRAME_PROVIDERS
        lea     rsi, [tui_staged_responses + TUI_S_PRIMARY]
        call    _af_tuir_apply_staged_frame
        test    rax, rax
        js      .rollback
        call    _af_tuir_provider_get
        test    rax, rax
        js      .rollback
        lea     rdi, [tui_responses + TUI_R_PROVIDERS]
        lea     rsi, [tui_staged_responses + TUI_S_PRIMARY]
        call    _af_tuir_swap_buffers
        xor     eax, eax
        jmp     .done
.rollback:
        mov     r12, rax
        mov     edi, TUI_MODEL_FRAME_PROVIDERS
        lea     rsi, [tui_responses + TUI_R_PROVIDERS]
        call    _af_tuir_apply_staged_frame
        mov     edi, AF_TUI_SCREEN_PROVIDERS
        xor     esi, esi
        call    _af_tuir_restore_selection
        mov     rax, r12
.done:
        AF_LEAVE
.state:
        AF_LEAVE_ERR AF_E_CTL_STATE

; _af_tuir_refresh_frame(kind, method, method_len, response_buf) -> af_status.
; The complete correlated envelope replaces the corresponding model document
; only after the bounded control call succeeds.
_af_tuir_refresh_frame:
        AF_ENTER 0
        mov     r9, rcx
        xor     ecx, ecx
        xor     r8d, r8d
        call    _af_tuir_call
        AF_LEAVE

; Refresh the current screen through its existing control-frame contract.
; Overview is a composite and therefore refreshes exactly the four documents
; it presents. Requests and Logs retain their explicit unavailable envelopes.
_af_tuir_refresh_current:
        AF_ENTER 0
        cmp     qword [tui_connection_state], AF_TUI_CONN_CONNECTED
        jne     .state
        mov     rbx, [tui_current_screen]
        cmp     rbx, AF_TUI_SCREEN_OVERVIEW
        je      .overview
        cmp     rbx, AF_TUI_SCREEN_PROVIDERS
        je      .providers
        cmp     rbx, AF_TUI_SCREEN_ROUTES
        je      .routes
        cmp     rbx, AF_TUI_SCREEN_REQUESTS
        je      .requests
        cmp     rbx, AF_TUI_SCREEN_MCP
        je      .mcp
        cmp     rbx, AF_TUI_SCREEN_LOGS
        je      .logs
        cmp     rbx, AF_TUI_SCREEN_SETTINGS
        je      .settings
        jmp     .invalid

.overview:
        mov     edi, AF_TUI_SCREEN_PROVIDERS
        xor     esi, esi
        call    _af_tuir_save_selection
        test    rax, rax
        js      .done
        mov     edi, AF_TUI_SCREEN_ROUTES
        mov     esi, 1
        call    _af_tuir_save_selection
        test    rax, rax
        js      .done
        xor     edi, edi
        lea     rsi, [tui_method_snapshot]
        mov     edx, tui_method_snapshot_len
        xor     ecx, ecx
        xor     r8d, r8d
        lea     r9, [tui_staged_responses + TUI_S_PRIMARY]
        call    _af_tuir_call
        test    rax, rax
        js      .done
        xor     edi, edi
        lea     rsi, [tui_method_providers]
        mov     edx, tui_method_providers_len
        xor     ecx, ecx
        xor     r8d, r8d
        lea     r9, [tui_staged_responses + TUI_S_SECONDARY]
        call    _af_tuir_call
        test    rax, rax
        js      .done
        xor     edi, edi
        lea     rsi, [tui_method_routes]
        mov     edx, tui_method_routes_len
        xor     ecx, ecx
        xor     r8d, r8d
        lea     r9, [tui_staged_responses + TUI_S_TERTIARY]
        call    _af_tuir_call
        test    rax, rax
        js      .done
        xor     edi, edi
        lea     rsi, [tui_method_mcp]
        mov     edx, tui_method_mcp_len
        xor     ecx, ecx
        xor     r8d, r8d
        lea     r9, [tui_staged_responses + TUI_S_QUATERNARY]
        call    _af_tuir_call
        test    rax, rax
        js      .done

        mov     edi, TUI_MODEL_FRAME_SNAPSHOT
        lea     rsi, [tui_staged_responses + TUI_S_PRIMARY]
        call    _af_tuir_apply_staged_frame
        test    rax, rax
        js      .overview_rollback
        mov     edi, TUI_MODEL_FRAME_PROVIDERS
        lea     rsi, [tui_staged_responses + TUI_S_SECONDARY]
        call    _af_tuir_apply_staged_frame
        test    rax, rax
        js      .overview_rollback
        mov     edi, TUI_MODEL_FRAME_ROUTES
        lea     rsi, [tui_staged_responses + TUI_S_TERTIARY]
        call    _af_tuir_apply_staged_frame
        test    rax, rax
        js      .overview_rollback
        mov     edi, TUI_MODEL_FRAME_MCP
        lea     rsi, [tui_staged_responses + TUI_S_QUATERNARY]
        call    _af_tuir_apply_staged_frame
        test    rax, rax
        js      .overview_rollback

        lea     rdi, [tui_responses + TUI_R_SNAPSHOT]
        lea     rsi, [tui_staged_responses + TUI_S_PRIMARY]
        call    _af_tuir_swap_buffers
        lea     rdi, [tui_responses + TUI_R_PROVIDERS]
        lea     rsi, [tui_staged_responses + TUI_S_SECONDARY]
        call    _af_tuir_swap_buffers
        lea     rdi, [tui_responses + TUI_R_ROUTES]
        lea     rsi, [tui_staged_responses + TUI_S_TERTIARY]
        call    _af_tuir_swap_buffers
        lea     rdi, [tui_responses + TUI_R_MCP]
        lea     rsi, [tui_staged_responses + TUI_S_QUATERNARY]
        call    _af_tuir_swap_buffers
        xor     eax, eax
        jmp     .done

.overview_rollback:
        mov     r12, rax
        mov     edi, TUI_MODEL_FRAME_SNAPSHOT
        lea     rsi, [tui_responses + TUI_R_SNAPSHOT]
        call    _af_tuir_apply_staged_frame
        mov     edi, TUI_MODEL_FRAME_PROVIDERS
        lea     rsi, [tui_responses + TUI_R_PROVIDERS]
        call    _af_tuir_apply_staged_frame
        mov     edi, TUI_MODEL_FRAME_ROUTES
        lea     rsi, [tui_responses + TUI_R_ROUTES]
        call    _af_tuir_apply_staged_frame
        mov     edi, TUI_MODEL_FRAME_MCP
        lea     rsi, [tui_responses + TUI_R_MCP]
        call    _af_tuir_apply_staged_frame
        mov     edi, AF_TUI_SCREEN_PROVIDERS
        xor     esi, esi
        call    _af_tuir_restore_selection
        mov     edi, AF_TUI_SCREEN_ROUTES
        mov     esi, 1
        call    _af_tuir_restore_selection
        mov     rax, r12
        jmp     .done

.providers:
        call    _af_tuir_provider_refresh
        jmp     .done
.routes:
        mov     edi, TUI_MODEL_FRAME_ROUTES
        lea     rsi, [tui_method_routes]
        mov     edx, tui_method_routes_len
        lea     rcx, [tui_responses + TUI_R_ROUTES]
        call    _af_tuir_refresh_frame
        jmp     .done
.requests:
        mov     edi, TUI_MODEL_FRAME_REQUESTS
        lea     rsi, [tui_method_requests]
        mov     edx, tui_method_requests_len
        lea     rcx, [tui_responses + TUI_R_REQUESTS]
        call    _af_tuir_refresh_frame
        jmp     .done
.mcp:
        mov     edi, TUI_MODEL_FRAME_MCP
        lea     rsi, [tui_method_mcp]
        mov     edx, tui_method_mcp_len
        lea     rcx, [tui_responses + TUI_R_MCP]
        call    _af_tuir_refresh_frame
        jmp     .done
.logs:
        mov     edi, TUI_MODEL_FRAME_LOGS
        lea     rsi, [tui_method_logs]
        mov     edx, tui_method_logs_len
        lea     rcx, [tui_responses + TUI_R_LOGS]
        call    _af_tuir_refresh_frame
        jmp     .done
.settings:
        mov     edi, TUI_MODEL_FRAME_CONFIG
        lea     rsi, [tui_method_config]
        mov     edx, tui_method_config_len
        lea     rcx, [tui_responses + TUI_R_CONFIG]
        call    _af_tuir_refresh_frame
.done:
        AF_LEAVE
.state:
        AF_LEAVE_ERR AF_E_CTL_STATE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; _af_tuir_move_selection(TKE command) -> af_status.
; All row-bearing models share stable selection. Providers additionally fetch
; their selected detail; MCP selection is deliberately local until an action
; serialises that server's stable ID.
_af_tuir_move_selection:
        AF_ENTER 0
        mov     rbx, rdi
        mov     rdi, [tui_current_screen]
        cmp     rbx, AF_TUI_CMD_ROW_PREV
        je      .previous
        call    af_tui_model_select_next
        jmp     .selected
.previous:
        call    af_tui_model_select_prev
.selected:
        test    rax, rax
        jns     .has_row
        cmp     rax, AF_E_NOTFOUND
        je      .ok
        jmp     .done
.has_row:
        cmp     qword [tui_current_screen], AF_TUI_SCREEN_PROVIDERS
        jne     .ok
        call    _af_tuir_provider_get
        test    rax, rax
        jns     .ok
        mov     qword [tui_connection_state], AF_TUI_CONN_STALE
        jmp     .done
.ok:
        xor     eax, eax
.done:
        AF_LEAVE

_af_tuir_mcp_restart:
        AF_ENTER 0
        cmp     qword [tui_connection_state], AF_TUI_CONN_CONNECTED
        jne     .state
        mov     edi, AF_TUI_SCREEN_MCP
        lea     rsi, [tui_key_server_id]
        call    _af_tuir_build_selected_params
        test    rax, rax
        js      .done
        lea     rdi, [tui_params_buffer]
        call    af_buf_data
        mov     r12, rax
        lea     rdi, [tui_params_buffer]
        call    af_buf_len
        mov     r13, rax
        xor     edi, edi
        lea     rsi, [tui_method_mcp_restart]
        mov     edx, tui_method_mcp_restart_len
        mov     rcx, r12
        mov     r8, r13
        lea     r9, [tui_responses + TUI_R_ACTION]
        call    _af_tuir_call
.done:
        AF_LEAVE
.state:
        AF_LEAVE_ERR AF_E_CTL_STATE

_af_tuir_command_is_restart:
        cmp     qword [tui_command_len], tui_command_restart_len
        jne     .no
        lea     r8, [tui_command_buffer]
        lea     r9, [tui_command_restart]
        xor     ecx, ecx
.byte:
        cmp     rcx, tui_command_restart_len
        jae     .yes
        mov     al, [r8 + rcx]
        cmp     al, [r9 + rcx]
        jne     .no
        inc     rcx
        jmp     .byte
.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

; _af_tuir_handle_key(i64 key) -> 1 to quit, otherwise 0.
;
; Confirmation and command-entry modes consume raw keys first. Normal mode has
; exactly one canonical mapping path through af_tui_keymap/TKE_COMMAND.
_af_tuir_handle_key:
        AF_ENTER 16
        mov     rbx, rdi
        cmp     qword [tui_confirmation], 0
        jne     .confirmation
        cmp     qword [tui_command_active], 0
        jne     .command

        mov     rdi, rbx
        lea     rsi, [rsp]
        call    af_tui_keymap
        test    rax, rax
        js      .stay
        mov     r12, [rsp + TKE_COMMAND]
        mov     r13, [rsp + TKE_ARGUMENT]

        ; HELP is an overlay: Escape or a second '?' closes it, q remains an
        ; unconditional exit, and direct navigation closes it deterministically.
        cmp     qword [tui_help_visible], 0
        je      .dispatch
        cmp     r12, AF_TUI_CMD_BACK
        je      .close_help
        cmp     r12, AF_TUI_CMD_HELP
        je      .close_help
        cmp     r12, AF_TUI_CMD_QUIT
        je      .quit
        cmp     r12, AF_TUI_CMD_SCREEN
        je      .screen
        jmp     .stay

.dispatch:
        cmp     r12, AF_TUI_CMD_QUIT
        je      .quit
        cmp     r12, AF_TUI_CMD_SCREEN
        je      .screen
        cmp     r12, AF_TUI_CMD_HELP
        je      .help
        cmp     r12, AF_TUI_CMD_PALETTE
        je      .palette
        cmp     r12, AF_TUI_CMD_BACK
        je      .close_help
        cmp     r12, AF_TUI_CMD_ROW_NEXT
        je      .move
        cmp     r12, AF_TUI_CMD_ROW_PREV
        je      .move
        cmp     r12, AF_TUI_CMD_REFRESH
        je      .refresh
        ; Focus, filter, open, and multi-select are deliberately unavailable
        ; in this build and are not advertised by the command bar or HELP.
        jmp     .stay

.screen:
        mov     [tui_current_screen], r13
        mov     qword [tui_help_visible], 0
        jmp     .stay
.help:
        mov     qword [tui_help_visible], 1
        jmp     .stay
.close_help:
        mov     qword [tui_help_visible], 0
        jmp     .stay
.palette:
        mov     qword [tui_command_active], 1
        mov     qword [tui_command_len], 0
        mov     qword [tui_help_visible], 0
        jmp     .stay
.move:
        mov     rdi, r12
        call    _af_tuir_move_selection
        jmp     .stay
.refresh:
        cmp     qword [tui_connection_state], AF_TUI_CONN_CONNECTED
        jne     .reconnect
        call    _af_tuir_refresh_current
        test    rax, rax
        jns     .stay
        mov     qword [tui_connection_state], AF_TUI_CONN_STALE
        jmp     .stay
.reconnect:
        call    _af_tuir_reconnect
        jmp     .stay

.confirmation:
        cmp     rbx, 27
        je      .cancel_confirmation
        cmp     rbx, 10
        je      .accept_confirmation
        cmp     rbx, 13
        je      .accept_confirmation
        cmp     rbx, AF_TUI_KEY_ENTER
        jne     .stay
.accept_confirmation:
        mov     qword [tui_confirmation], 0
        call    _af_tuir_mcp_restart
        test    rax, rax
        jns     .stay
        mov     qword [tui_connection_state], AF_TUI_CONN_STALE
        jmp     .stay
.cancel_confirmation:
        mov     qword [tui_confirmation], 0
        jmp     .stay

.command:
        cmp     rbx, 27
        je      .cancel_command
        cmp     rbx, 10
        je      .submit_command
        cmp     rbx, 13
        je      .submit_command
        cmp     rbx, AF_TUI_KEY_ENTER
        je      .submit_command
        cmp     rbx, 0x20
        jb      .stay
        cmp     rbx, 0x7e
        ja      .stay
        mov     rcx, [tui_command_len]
        cmp     rcx, TUI_COMMAND_CAPACITY - 1
        jae     .stay
        lea     rax, [tui_command_buffer]
        mov     [rax + rcx], bl
        inc     qword [tui_command_len]
        jmp     .stay
.submit_command:
        call    _af_tuir_command_is_restart
        mov     qword [tui_command_active], 0
        mov     qword [tui_command_len], 0
        test    rax, rax
        jz      .stay
        mov     edi, AF_TUI_ACTION_MCP_RESTART
        call    af_tui_action_descriptor
        test    rax, rax
        jz      .stay
        mov     r12, rax
        mov     rdi, r12
        call    af_tui_action_available
        test    rax, rax
        jz      .stay
        mov     rdi, r12
        call    af_tui_action_requires_confirmation
        test    rax, rax
        jz      .stay
        call    _af_tuir_prepare_confirmation
        test    rax, rax
        js      .stay
        mov     qword [tui_confirmation], 1
        jmp     .stay
.cancel_command:
        mov     qword [tui_command_active], 0
        mov     qword [tui_command_len], 0
.stay:
        xor     eax, eax
        AF_LEAVE
.quit:
        mov     eax, 1
        AF_LEAVE

; Nonblocking EOF detection. A positive byte is an unsolicited event/frame,
; a negative result is the normal EAGAIN state, and zero is peer shutdown.
_af_tuir_poll_connection:
        AF_ENTER 16
        cmp     qword [tui_connection_state], AF_TUI_CONN_DISCONNECTED
        je      .done
        lea     rdi, [tui_client]
        call    af_ctl_client_fd
        mov     rdi, rax
        lea     rsi, [rsp]
        mov     edx, 1
        mov     ecx, MSG_PEEK | MSG_DONTWAIT
        xor     r8d, r8d
        xor     r9d, r9d
        call    af_sys_recvfrom
        test    rax, rax
        jg      .done
        jz      .disconnected
        ; A nonblocking empty socket reports EAGAIN; an interrupted peek is
        ; retried on the next loop turn. All other negative errno values mean
        ; the control connection is no longer usable.
        cmp     rax, -11                 ; EAGAIN/EWOULDBLOCK on Linux
        je      .done
        cmp     rax, -4                  ; EINTR
        je      .done
.disconnected:
        mov     qword [tui_connection_state], AF_TUI_CONN_DISCONNECTED
.done:
        AF_LEAVE

; Retry is screen-independent and reuses the exact original socket path.
_af_tuir_reconnect:
        AF_ENTER 0
        cmp     qword [tui_client_ready], 0
        je      .open
        lea     rdi, [tui_client]
        call    af_ctl_client_close
        mov     qword [tui_client_ready], 0
.open:
        lea     rdi, [tui_client]
        mov     rsi, [tui_socket_path]
        call    af_ctl_client_init
        test    rax, rax
        js      .failed
        mov     qword [tui_client_ready], 1
        call    _af_tuir_bootstrap
        test    rax, rax
        js      .close_failed
        mov     qword [tui_connection_state], AF_TUI_CONN_CONNECTED
        xor     eax, eax
        AF_LEAVE
.close_failed:
        mov     r12, rax
        lea     rdi, [tui_client]
        call    af_ctl_client_close
        mov     qword [tui_client_ready], 0
        mov     rax, r12
.failed:
        mov     qword [tui_connection_state], AF_TUI_CONN_DISCONNECTED
        AF_LEAVE

_af_tuir_interactive:
        AF_ENTER 0
        call    _af_tuir_terminal_init
        test    rax, rax
        js      .failed
        call    _af_tuir_present
        test    rax, rax
        js      .failed_cleanup
.loop:
        call    _af_tuir_signal_pending
        test    rax, rax
        jnz     .ok_cleanup
        mov     rdi, [tui_window]
        AF_CCALL wgetch
        movsxd  rbx, eax
        call    af_ncc_err
        cmp     rbx, rax
        je      .poll
        mov     rdi, rbx
        call    _af_tuir_handle_key
        test    rax, rax
        jnz     .ok_cleanup
.poll:
        call    _af_tuir_poll_connection
        call    _af_tuir_present
        test    rax, rax
        jns     .loop
.failed_cleanup:
        call    _af_tuir_terminal_cleanup
.failed:
        mov     eax, AF_EXIT_FAILURE
        AF_LEAVE
.ok_cleanup:
        call    _af_tuir_terminal_cleanup
        mov     eax, AF_EXIT_OK
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_tui_run(socket_path_or_null, flags, dump_width, dump_height, screen)
;   -> process exit code.
; ---------------------------------------------------------------------------
        global af_tui_run
af_tui_run:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        mov     r15, r8
        mov     qword [tui_client_ready], 0
        mov     qword [tui_curses_ready], 0
        mov     qword [tui_signals_blocked], 0
        mov     qword [tui_signal_fd], -1
        mov     qword [tui_previous_cursor], 1
        mov     qword [tui_command_active], 0
        mov     qword [tui_command_len], 0
        mov     qword [tui_confirmation], 0
        mov     qword [tui_help_visible], 0
        mov     qword [tui_connection_state], AF_TUI_CONN_CONNECTED
        mov     [tui_current_screen], r15
        mov     [tui_width], r13
        mov     [tui_height], r14
        ; ncursesw and libc width classification both require the process
        ; locale to be activated explicitly; LC_ALL="" selects the already
        ; bounded environment supplied at process start. Failure leaves the C
        ; locale in force and the renderer's ASCII fallback remains usable.
        mov     edi, LC_ALL
        lea     rsi, [tui_locale_from_environment]
        AF_CCALL setlocale
        call    _af_tuir_buffers_init
        test    rax, rax
        js      .runtime_error
        test    rbx, rbx
        jnz     .path_ready
        call    _af_tuir_default_path
        test    rax, rax
        js      .connect_error
        mov     rbx, rax
.path_ready:
        mov     [tui_socket_path], rbx
        lea     rdi, [tui_client]
        mov     rsi, rbx
        call    af_ctl_client_init
        test    rax, rax
        js      .connect_error
        mov     qword [tui_client_ready], 1
        call    _af_tuir_bootstrap
        test    rax, rax
        js      .protocol_error
        test    r12, TUI_FLAG_DUMP
        jz      .interactive
        call    _af_tuir_dump_stdout
        test    rax, rax
        js      .runtime_error
        mov     qword [rsp], AF_EXIT_OK
        jmp     .cleanup
.interactive:
        call    _af_tuir_interactive
        mov     [rsp], rax
        jmp     .cleanup
.connect_error:
        mov     edi, AF_FD_STDERR
        lea     rsi, [tui_err_connect]
        mov     rdx, tui_err_connect_len
        call    af_write_all
        mov     qword [rsp], AF_EXIT_FAILURE
        jmp     .cleanup
.protocol_error:
        mov     edi, AF_FD_STDERR
        lea     rsi, [tui_err_protocol]
        mov     rdx, tui_err_protocol_len
        call    af_write_all
        mov     qword [rsp], AF_EXIT_FAILURE
        jmp     .cleanup
.runtime_error:
        mov     edi, AF_FD_STDERR
        lea     rsi, [tui_err_runtime]
        mov     rdx, tui_err_runtime_len
        call    af_write_all
        mov     qword [rsp], AF_EXIT_FAILURE
.cleanup:
        call    _af_tuir_terminal_cleanup
        cmp     qword [tui_client_ready], 0
        je      .buffers
        lea     rdi, [tui_client]
        call    af_ctl_client_close
        mov     qword [tui_client_ready], 0
.buffers:
        call    _af_tuir_buffers_free
        call    af_tui_model_reset
        mov     rax, [rsp]
        AF_LEAVE
