; AsmFlow -- control response kinds consumed by the TUI presentation model.
;
; `af_tui_model_reset()` releases all model-owned documents and selection.
; `af_tui_model_set_frame(rdi=kind,rsi=bytes,rdx=len)` takes one complete
; response envelope.  Input bytes are BORROWED for that call; the model owns
; the bounded parsed document after success.
; `af_tui_model_build(rdi=screen_id,rsi=connection)` returns BORROWED
; process-local presentation storage valid until the next model API call.
; af_tui_model_select_next(rdi=screen_id) and
; af_tui_model_select_prev(rdi=screen_id) mutate model-owned focus.
; `af_tui_model_selected_id(rdi=screen_id,rsi=&ptr,rdx=&len)` returns a
; BORROWED stable-ID span written only on success; it remains valid until
; reset, a list-frame replacement, or another selection mutation.

%ifndef ASMFLOW_TUI_MODEL_INC
%define ASMFLOW_TUI_MODEL_INC

%define AF_TUI_MODEL_KIND_VERSION   1
%define AF_TUI_MODEL_KIND_SNAPSHOT  2
%define AF_TUI_MODEL_KIND_PROVIDERS 3
%define AF_TUI_MODEL_KIND_ROUTES    4
%define AF_TUI_MODEL_KIND_REQUESTS  5
%define AF_TUI_MODEL_KIND_MCP       6
%define AF_TUI_MODEL_KIND_LOGS      7
%define AF_TUI_MODEL_KIND_CONFIG    8
%define AF_TUI_MODEL_KIND_COUNT     8

%define AF_TUI_MODEL_FRAME_MAX      (1024 * 1024)
%define AF_TUI_MODEL_JSON_DEPTH     64
%define AF_TUI_MODEL_JSON_ELEMENTS  10000

%endif ; ASMFLOW_TUI_MODEL_INC
