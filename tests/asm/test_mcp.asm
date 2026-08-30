; AsmFlow — MCP stdio message and supervision unit tests (HARNESS.md M8).
;
; A live child and its pipes belong in the Python integration suites.  The
; decidable boundaries belong here: argv/env construction, line ceilings and
; resynchronisation, JSON-RPC correlation, bounded stderr, and restart-budget
; accounting.  Every owned block or embedded buffer is released in the test
; that acquired it so the runner's per-test leak check remains meaningful.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "fileio.inc"
%include "loop.inc"
%include "config.inc"
%include "mcp.inc"
%include "test.inc"

%define AF_TEST_TAG mcp

; The fixed source budget must cover every bounded client plus both persistent
; read watches for every stdio child, while staying small enough for the daemon's
; heap-owned context and loop unit allocations.
%define MCP_LOOP_PLANNED_SOURCES (128 + 64 + AF_MCP_MAX_CHILDREN * 2 + 320)
AF_STATIC_ASSERT AF_LOOP_MAX_SOURCES >= MCP_LOOP_PLANNED_SOURCES, "MCP source budget exceeds loop capacity"
AF_STATIC_ASSERT AF_LOOP_MAX_SOURCES <= 1024, "loop source table lost its bounded ceiling"
AF_STATIC_ASSERT LOOP_SIZE <= (64 * 1024), "loop structure no longer fits its 64 KiB size contract"

%define TEST_BUF_MAX 24

        extern af_mem_zero
        extern af_alloc
        extern af_free
        extern af_alloc_inject_failure_at
        extern af_alloc_reset_counters

        extern af_buf_init
        extern af_buf_free
        extern af_buf_data
        extern af_buf_len
        extern af_buf_append

        extern af_mcp_build_argv
        extern af_mcp_build_env
        extern af_mcp_frame_lines
        extern af_mcp_send
        extern af_mcp_on_message
        extern af_mcp_call_alloc
        extern af_mcp_calls_release
        extern af_mcp_sweep_calls
        extern af_mcp_request
        extern af_mcp_advance
        extern af_mcp_reap
        extern af_mcp_capture_stderr
        extern af_mcp_flush_errline
        extern af_mcp_schedule_restart
        extern af_mcp_sweep_child
        extern af_mcp_on_tick
        extern af_mcp_refresh_inventory
        extern af_mcp_collect_list
        extern af_mcp_child_failed
        extern af_mcp_stop
        extern af_mcp_start
        extern af_mcp_reset
        extern af_mcp_teardown

        extern af_clock_set_override_ns
        extern af_sys_pipe2
        extern af_sys_close
        extern af_sys_getpid

        extern setenv
        extern unsetenv

        section .rodata

argv_command: db "/usr/bin/python3", 0
argv_one:     db "two words", 0
argv_two:     db "semi;colon", 0
argv_three:   db "$(whoami)", 0
argv_four:    db "a|b", 0
argv_five:    db "x&&y", 0

env_path:     db "PATH", 0
env_unset:    db "ASMFLOW_MCP_TEST_DEFINITELY_UNSET_7F33C2A9", 0
env_prefix:   db "PATH=", 0
env_mapped_name: db "A_VERY_LONG_CHILD_VARIABLE", 0
env_mapped_prefix: db "A_VERY_LONG_CHILD_VARIABLE="
env_mapped_prefix_len equ $ - env_mapped_prefix
env_bound_source: db "ASMFLOW_MCP_BOUND_SOURCE", 0
env_bound_0: db "BOUND_0", 0
env_bound_1: db "BOUND_1", 0
env_bound_2: db "BOUND_2", 0
env_bound_3: db "BOUND_3", 0
env_bound_4: db "BOUND_4", 0
env_bound_5: db "BOUND_5", 0
env_bound_6: db "BOUND_6", 0
env_bound_7: db "BOUND_7", 0
env_bound_8: db "BOUND_8", 0
env_bound_names:
        dd env_bound_0 - env_bound_names
        dd env_bound_1 - env_bound_names
        dd env_bound_2 - env_bound_names
        dd env_bound_3 - env_bound_names
        dd env_bound_4 - env_bound_names
        dd env_bound_5 - env_bound_names
        dd env_bound_6 - env_bound_names
        dd env_bound_7 - env_bound_names
        dd env_bound_8 - env_bound_names

json_note: db `{"jsonrpc":"2.0","method":"ping"}`
json_note_len equ $ - json_note
json_note_line:
        db `{"jsonrpc":"2.0","method":"ping"}`, 10
json_note_line_len equ $ - json_note_line
json_note_over_line:
        db `{"jsonrpc":"2.0","method":"ping"}`, " ", 10
json_note_over_line_len equ $ - json_note_over_line
frame_lf: db 10
frame_crlf: db 13, 10

fragment_oversized:
        times 65 db "x"
fragment_oversized_len equ $ - fragment_oversized
fragment_tail_and_note:
        db "tail", 10
        db `{"jsonrpc":"2.0","method":"ping"}`, 10
fragment_tail_and_note_len equ $ - fragment_tail_and_note

json_bad_line: db "not-json", 10
json_bad_line_len equ $ - json_bad_line
json_invalid_utf8_line:
        db `{"jsonrpc":"2.0","method":"p`
        db 0xc3, 0x28
        db `ng"}`, 10
json_invalid_utf8_line_len equ $ - json_invalid_utf8_line

json_response:
        db `{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}`
json_response_len equ $ - json_response
json_response_duplicate:
        db `{"jsonrpc":"2.0","id":1,"result":{"tools":[1]}}`
json_response_duplicate_len equ $ - json_response_duplicate
json_response_both:
        db `{"jsonrpc":"2.0","id":1,"result":{"tools":[]},"error":{"code":-1}}`
json_response_both_len equ $ - json_response_both
json_response_with_method:
        db `{"jsonrpc":"2.0","id":1,"method":"ping","result":{"tools":[]}}`
json_response_with_method_len equ $ - json_response_with_method
json_request_integer_id:
        db `{"jsonrpc":"2.0","id":7,"method":"sampling/createMessage","params":{}}`
json_request_integer_id_len equ $ - json_request_integer_id
json_request_string_id:
        db `{"jsonrpc":"2.0","id":"peer-7","method":"elicitation/create","params":{}}`
json_request_string_id_len equ $ - json_request_string_id
json_request_null_id_array_params:
        db `{"jsonrpc":"2.0","id":null,"method":"peer/ping","params":[]}`
json_request_null_id_array_params_len equ $ - json_request_null_id_array_params
json_request_object_id:
        db `{"jsonrpc":"2.0","id":{},"method":"peer/ping","params":{}}`
json_request_object_id_len equ $ - json_request_object_id
json_request_array_id:
        db `{"jsonrpc":"2.0","id":[],"method":"peer/ping","params":{}}`
json_request_array_id_len equ $ - json_request_array_id
json_request_bool_id:
        db `{"jsonrpc":"2.0","id":true,"method":"peer/ping","params":{}}`
json_request_bool_id_len equ $ - json_request_bool_id
json_request_real_id:
        db `{"jsonrpc":"2.0","id":1.5,"method":"peer/ping","params":{}}`
json_request_real_id_len equ $ - json_request_real_id
json_request_scalar_params:
        db `{"jsonrpc":"2.0","method":"peer/ping","params":"bad"}`
json_request_scalar_params_len equ $ - json_request_scalar_params
json_error_valid:
        db `{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"refused"}}`
json_error_valid_len equ $ - json_error_valid
json_error_scalar:
        db `{"jsonrpc":"2.0","id":1,"error":"refused"}`
json_error_scalar_len equ $ - json_error_scalar
json_error_missing_code:
        db `{"jsonrpc":"2.0","id":1,"error":{"message":"refused"}}`
json_error_missing_code_len equ $ - json_error_missing_code
json_error_missing_message:
        db `{"jsonrpc":"2.0","id":1,"error":{"code":-32001}}`
json_error_missing_message_len equ $ - json_error_missing_message
json_cancelled_one:
        db `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1,"reason":"request timeout"}}`, 10
json_cancelled_one_len equ $ - json_cancelled_one
json_result: db `{"tools":[]}`
json_result_len equ $ - json_result
json_method_number: db `{"jsonrpc":"2.0","method":7}`
json_method_number_len equ $ - json_method_number
stale_result: db "stale"
stale_result_len equ $ - stale_result
request_method: db "resources/list", 0

inventory_tools_scalar: db `{"tools":[42]}`
inventory_tools_scalar_len equ $ - inventory_tools_scalar
inventory_tools_empty: db `{"tools":[{}]}`
inventory_tools_empty_len equ $ - inventory_tools_empty
inventory_tools_bad_schema: db `{"tools":[{"name":"echo","inputSchema":[]}]}`
inventory_tools_bad_schema_len equ $ - inventory_tools_bad_schema
inventory_tools_valid: db `{"tools":[{"name":"echo","inputSchema":{}}]}`
inventory_tools_valid_len equ $ - inventory_tools_valid
inventory_tools_valid_cache: db `[{"name":"echo","inputSchema":{}}]`
inventory_tools_valid_cache_len equ $ - inventory_tools_valid_cache
inventory_resources_missing_uri: db `{"resources":[{"name":"manual"}]}`
inventory_resources_missing_uri_len equ $ - inventory_resources_missing_uri
inventory_prompts_empty_name: db `{"prompts":[{"name":""}]}`
inventory_prompts_empty_name_len equ $ - inventory_prompts_empty_name
inventory_old_tools: db `[{"name":"old","inputSchema":{}}]`
inventory_old_tools_len equ $ - inventory_old_tools
inventory_old_resources: db `[{"uri":"file:///old","name":"old"}]`
inventory_old_resources_len equ $ - inventory_old_resources
inventory_old_prompts: db `[{"name":"old"}]`
inventory_old_prompts_len equ $ - inventory_old_prompts

send_seed_byte: db "s"
send_line_four: db "line"
send_seed_63: times 63 db "s"

stderr_long_line: db "abcdef", 10
stderr_long_line_len equ $ - stderr_long_line
stderr_kept: db "abcd", 10
stderr_kept_len equ $ - stderr_kept
stderr_previous: db "old tail", 10
stderr_previous_len equ $ - stderr_previous
stderr_over_keep_line:
        times 9 db "p"
stderr_over_keep_suffix:
        db "suffix"
        times (AF_MCP_STDERR_KEEP - 7) db "s"
        db 10
stderr_over_keep_line_len equ $ - stderr_over_keep_line
stderr_over_keep_payload_len equ stderr_over_keep_line_len - 1
stderr_over_keep_expected_len equ $ - stderr_over_keep_suffix

        section .text

; ---------------------------------------------------------------------------
; Process-vector construction.
; ---------------------------------------------------------------------------

        AF_TEST "mcp/process/argv_is_literal_and_null_terminated", 512
%define AV_CFG  0
%define AV_ARGS 256
%define AV_OUT  320
        lea     rdi, [rsp]
        mov     rsi, 384
        call    af_mem_zero

        lea     rax, [argv_command]
        mov     [rsp + AV_CFG + MCP_COMMAND], rax
        lea     rax, [rsp + AV_ARGS]
        mov     [rsp + AV_CFG + MCP_ARGS], rax
        mov     qword [rsp + AV_CFG + MCP_ARG_COUNT], 5

        lea     rax, [argv_one]
        mov     [rsp + AV_ARGS + 0], rax
        lea     rax, [argv_two]
        mov     [rsp + AV_ARGS + 8], rax
        lea     rax, [argv_three]
        mov     [rsp + AV_ARGS + 16], rax
        lea     rax, [argv_four]
        mov     [rsp + AV_ARGS + 24], rax
        lea     rax, [argv_five]
        mov     [rsp + AV_ARGS + 32], rax

        lea     rdi, [rsp + AV_CFG]
        lea     rsi, [rsp + AV_OUT]
        call    af_mcp_build_argv
        AF_CHECK_OK rax, "building argv should succeed"
        mov     rbx, [rsp + AV_OUT]
        AF_CHECK_NE rbx, 0, "argv must be returned"

        lea     r12, [argv_command]
        AF_CHECK_EQ qword [rbx + 0], r12, "argv[0] is the configured command"
        lea     r12, [argv_one]
        AF_CHECK_EQ qword [rbx + 8], r12, "spaces remain literal"
        lea     r12, [argv_two]
        AF_CHECK_EQ qword [rbx + 16], r12, "semicolon remains literal"
        lea     r12, [argv_three]
        AF_CHECK_EQ qword [rbx + 24], r12, "command substitution remains literal"
        lea     r12, [argv_four]
        AF_CHECK_EQ qword [rbx + 32], r12, "pipe remains literal"
        lea     r12, [argv_five]
        AF_CHECK_EQ qword [rbx + 40], r12, "and-list remains literal"
        AF_CHECK_EQ qword [rbx + 48], 0, "argv is NULL terminated"

        mov     rdi, rbx
        call    af_free
        AF_TEST_END

        AF_TEST "mcp/process/environment_contains_only_set_allowlisted_names", 512
%define EV_CFG   0
%define EV_ALLOW 256
%define EV_OUT   288
%define EV_PAIRS 304
        lea     rdi, [rsp]
        mov     rsi, 384
        call    af_mem_zero

        lea     rax, [rsp + EV_ALLOW]
        mov     [rsp + EV_CFG + MCP_ENV_ALLOW], rax
        mov     qword [rsp + EV_CFG + MCP_ENV_ALLOW_COUNT], 2
        lea     rax, [env_path]
        mov     [rsp + EV_ALLOW + 0], rax
        lea     rax, [env_unset]
        mov     [rsp + EV_ALLOW + 8], rax
        lea     rax, [rsp + EV_PAIRS]
        mov     [rsp + EV_CFG + MCP_ENV_PAIRS], rax
        mov     qword [rsp + EV_CFG + MCP_ENV_PAIR_COUNT], 1
        lea     rax, [env_mapped_name]
        mov     [rsp + EV_PAIRS + ENVP_NAME], rax
        lea     rax, [env_path]
        mov     [rsp + EV_PAIRS + ENVP_ENV], rax

        lea     rdi, [rsp + EV_CFG]
        lea     rsi, [rsp + EV_OUT]
        call    af_mcp_build_env
        AF_CHECK_OK rax, "building the allowlisted environment should succeed"
        mov     rbx, [rsp + EV_OUT]
        AF_CHECK_NE rbx, 0, "envp must be returned"
        mov     r12, [rbx]
        AF_CHECK_NE r12, 0, "the existing PATH entry must be present"
        lea     r13, [env_prefix]
        AF_CHECK_MEM_EQ r12, r13, 5, "the inherited entry is PATH=value"
        mov     r12, [rbx + 8]
        AF_CHECK_NE r12, 0, "the mapped PATH entry must be present"
        lea     r13, [env_mapped_prefix]
        AF_CHECK_MEM_EQ r12, r13, env_mapped_prefix_len, "mapped entry sizing uses the longer child-side name"
        AF_CHECK_EQ qword [rbx + 16], 0, "the unset allowlisted name is omitted and envp is terminated"

        mov     rdi, rbx
        call    af_free
        AF_TEST_END

        AF_TEST "mcp/process/environment_total_includes_the_pointer_array", 512
%define EB_CFG   0
%define EB_PAIRS 256
%define EB_OUT   416
%define EB_VALUE_LEN 116499
        lea     rdi, [rsp]
        mov     rsi, 512
        call    af_mem_zero
        mov     rdi, EB_VALUE_LEN + 1
        call    af_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "large repeated source fixture allocation"
        xor     r12d, r12d
.fill_env_value:
        cmp     r12, EB_VALUE_LEN
        jae     .env_value_ready
        mov     byte [rbx + r12], 'x'
        inc     r12
        jmp     .fill_env_value
.env_value_ready:
        mov     byte [rbx + EB_VALUE_LEN], 0
        lea     rdi, [env_bound_source]
        mov     rsi, rbx
        mov     rdx, 1
        AF_CCALL setenv
        AF_CHECK_EQ rax, 0, "install repeated host environment source"

        lea     rax, [rsp + EB_PAIRS]
        mov     [rsp + EB_CFG + MCP_ENV_PAIRS], rax
        mov     qword [rsp + EB_CFG + MCP_ENV_PAIR_COUNT], 9
        lea     r15, [env_bound_names]
        xor     r12d, r12d
.set_bound_pairs:
        cmp     r12, 9
        jae     .bound_pairs_ready
        movsxd  rax, dword [r15 + r12 * 4]
        add     rax, r15
        mov     r13, r12
        imul    r13, r13, ENVP_SIZE
        mov     [rsp + EB_PAIRS + r13 + ENVP_NAME], rax
        lea     rax, [env_bound_source]
        mov     [rsp + EB_PAIRS + r13 + ENVP_ENV], rax
        inc     r12
        jmp     .set_bound_pairs
.bound_pairs_ready:
        ; Nine strings total 1,048,572 bytes, four below the 1 MiB
        ; ceiling. Their ten-pointer envp array adds 80 bytes, so the complete
        ; one-allocation block must be rejected before allocation.
        lea     rdi, [rsp + EB_CFG]
        lea     rsi, [rsp + EB_OUT]
        call    af_mcp_build_env
        AF_CHECK_ERR rax, AF_E_LIMIT, "final env allocation includes pointer-array bytes in the hard bound"
        AF_CHECK_EQ qword [rsp + EB_OUT], 0, "env output remains NULL on aggregate limit failure"

        lea     rdi, [env_bound_source]
        AF_CCALL unsetenv
        AF_CHECK_EQ rax, 0, "remove repeated host environment source"
        mov     rdi, rbx
        call    af_free
        AF_TEST_END

        AF_TEST "mcp/process/reap_treats_raw_echild_as_already_collected", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        call    af_sys_getpid
        mov     [rsp + MC_PID], rax
        mov     qword [rsp + MC_PGID], 2147483647

        lea     rdi, [rsp]
        call    af_mcp_reap
        AF_CHECK_EQ rax, 1, "wait4 ECHILD means the process is already collected"
        AF_CHECK_EQ qword [rsp + MC_PID], 0, "an already-collected pid is cleared"
        AF_CHECK_EQ qword [rsp + MC_PGID], 2147483647, "reaping the leader preserves its process group for teardown"
        mov     rbx, [rsp + MC_FLAGS]
        and     rbx, AF_MC_F_REAPED
        AF_CHECK_TRUE rbx, "an already-collected process is marked reaped"
        AF_TEST_END

        AF_TEST "mcp/process/teardown_retires_saved_group_after_leader_reap", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_STDIN_FD], -1
        mov     qword [rsp + MC_STDOUT_FD], -1
        mov     qword [rsp + MC_STDERR_FD], -1
        mov     qword [rsp + MC_PID], 0
        ; This is above Linux PID_MAX_LIMIT, so kill(-pgid, SIGKILL) must report
        ; ESRCH. That is the already-gone success case and proves signalling
        ; uses the saved PGID rather than the now-zero direct PID.
        mov     qword [rsp + MC_PGID], 2147483647
        lea     rdi, [rsp]
        xor     esi, esi
        call    af_mcp_teardown
        AF_CHECK_EQ qword [rsp + MC_PGID], 0, "teardown clears a process group only after kill accepts or reports ESRCH"
        AF_TEST_END

; ---------------------------------------------------------------------------
; stdout line framing and protocol contamination.
; ---------------------------------------------------------------------------

        AF_TEST "mcp/frame/a_complete_line_obeys_the_frame_ceiling", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + MC_INBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "inbox init"
        mov     qword [rsp + MC_FRAME_MAX], json_note_len

        lea     rdi, [rsp + MC_INBOX]
        lea     rsi, [json_note_line]
        mov     rdx, json_note_line_len
        call    af_buf_append
        AF_CHECK_OK rax, "append exact-boundary frame"
        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        AF_CHECK_OK rax, "frame exact-boundary line"
        AF_CHECK_EQ qword [rsp + MC_OVERSIZED], 0, "the exact ceiling is accepted"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_IN], 1, "one exact-boundary frame was read"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 1, "the exact-boundary message was delivered"
        AF_CHECK_EQ qword [rsp + MC_SCAN_CURSOR], 0, "consuming a complete frame resets the scan cursor"

        lea     rdi, [rsp + MC_INBOX]
        lea     rsi, [json_note_over_line]
        mov     rdx, json_note_over_line_len
        call    af_buf_append
        AF_CHECK_OK rax, "append ceiling-plus-one frame"
        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "a complete oversized line fails the protocol session"
        AF_CHECK_EQ qword [rsp + MC_OVERSIZED], 1, "a complete oversized line is counted"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_IN], 1, "the oversized line is not delivered"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 1, "the oversized message is not parsed"
        AF_CHECK_EQ qword [rsp + MC_SCAN_CURSOR], 0, "rejecting a complete frame resets the scan cursor"

        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "both complete lines were consumed"
        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/frame/fragmented_near_limit_frame_scans_each_prefix_once", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + MC_INBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "inbox init"
        mov     qword [rsp + MC_FRAME_MAX], json_note_len

        lea     rdi, [rsp + MC_INBOX]
        lea     rsi, [json_note]
        mov     rdx, 9
        call    af_buf_append
        AF_CHECK_OK rax, "append first near-limit fragment"
        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        AF_CHECK_OK rax, "first incomplete fragment is retained"
        AF_CHECK_EQ qword [rsp + MC_SCAN_CURSOR], 9, "the first scanned prefix is remembered"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 0, "an incomplete frame is not delivered"

        lea     rdi, [rsp + MC_INBOX]
        lea     rsi, [json_note + 9]
        mov     rdx, json_note_len - 9
        call    af_buf_append
        AF_CHECK_OK rax, "append the rest of the exact-limit payload"
        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        AF_CHECK_OK rax, "an exact-limit payload without LF remains incomplete"
        AF_CHECK_EQ qword [rsp + MC_SCAN_CURSOR], json_note_len, "only the newly appended suffix advances the cursor"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 0, "payload completion alone is not a frame"

        lea     rdi, [rsp + MC_INBOX]
        lea     rsi, [frame_lf]
        mov     rdx, 1
        call    af_buf_append
        AF_CHECK_OK rax, "append the frame terminator"
        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        AF_CHECK_OK rax, "the exact-limit fragmented frame is delivered"
        AF_CHECK_EQ qword [rsp + MC_SCAN_CURSOR], 0, "delivery resets the cursor for the next frame"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_IN], 1, "one fragmented frame is counted"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 1, "the fragmented notification is delivered once"
        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "delivery consumes the fragmented frame"

        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/frame/blank_and_cr_only_lines_are_protocol_noise", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + MC_INBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "inbox init"
        mov     qword [rsp + MC_FRAME_MAX], 64

        lea     rdi, [rsp + MC_INBOX]
        lea     rsi, [frame_lf]
        mov     rdx, 1
        call    af_buf_append
        AF_CHECK_OK rax, "append blank line"
        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "a blank stdout line fails the protocol session"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 1, "blank stdout is counted as contamination"
        AF_CHECK_EQ qword [rsp + MC_SCAN_CURSOR], 0, "blank-line failure resets the scan cursor"

        lea     rdi, [rsp + MC_INBOX]
        lea     rsi, [frame_crlf]
        mov     rdx, 2
        call    af_buf_append
        AF_CHECK_OK rax, "append CR-only line"
        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "a CR-only stdout line fails the protocol session"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 2, "CR-only stdout is also contamination"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_IN], 2, "both complete noise frames reached strict validation"
        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "rejected noise lines are consumed"

        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/frame/fragmented_oversize_fails_the_protocol_session", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + MC_INBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "inbox init"
        mov     qword [rsp + MC_FRAME_MAX], 64

        lea     rdi, [rsp + MC_INBOX]
        lea     rsi, [fragment_oversized]
        mov     rdx, fragment_oversized_len
        call    af_buf_append
        AF_CHECK_OK rax, "append unterminated oversized fragment"
        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "an oversized accumulation fails the protocol session"
        AF_CHECK_EQ qword [rsp + MC_OVERSIZED], 1, "oversized accumulation is counted once"
        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "the failed unterminated accumulation is cleared"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_IN], 0, "an oversized accumulation is never delivered"
        AF_CHECK_EQ qword [rsp + MC_SCAN_CURSOR], 0, "clearing an oversized accumulation resets the scan cursor"

        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/frame/malformed_json_is_counted_as_contamination", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + MC_INBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "inbox init"
        mov     qword [rsp + MC_FRAME_MAX], 256

        lea     rdi, [rsp + MC_INBOX]
        lea     rsi, [json_bad_line]
        mov     rdx, json_bad_line_len
        call    af_buf_append
        AF_CHECK_OK rax, "append malformed line"
        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "malformed JSON fails the protocol session"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_IN], 1, "the complete line reached the message layer"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 1, "malformed JSON is protocol contamination"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 0, "malformed JSON is not a notification"
        AF_CHECK_EQ qword [rsp + MC_UNMATCHED], 0, "malformed JSON is not an unmatched response"

        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/frame/invalid_utf8_is_protocol_contamination", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + MC_INBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "inbox init"
        mov     qword [rsp + MC_FRAME_MAX], 256

        lea     rdi, [rsp + MC_INBOX]
        lea     rsi, [json_invalid_utf8_line]
        mov     rdx, json_invalid_utf8_line_len
        call    af_buf_append
        AF_CHECK_OK rax, "append invalid UTF-8 JSON-RPC line"
        lea     rdi, [rsp]
        call    af_mcp_frame_lines
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "invalid UTF-8 fails the protocol session"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_IN], 1, "the invalid UTF-8 frame reached validation"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 1, "invalid UTF-8 is protocol contamination"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 0, "invalid UTF-8 is never delivered"
        AF_CHECK_EQ qword [rsp + MC_UNMATCHED], 0, "invalid UTF-8 is not an unmatched response"
        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "the rejected UTF-8 frame is consumed"

        lea     rdi, [rsp + MC_INBOX]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/frame/non_string_method_is_protocol_contamination", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_FRAME_MAX], 256

        lea     rdi, [rsp]
        lea     rsi, [json_method_number]
        mov     rdx, json_method_number_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "a malformed JSON-RPC shape fails the protocol session"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 1, "a present non-string method is contamination"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 0, "a non-string method is not a notification or request"
        AF_CHECK_EQ qword [rsp + MC_UNMATCHED], 0, "a method-only malformed message is not a response"
        AF_TEST_END

        AF_TEST "mcp/frame/send_newline_limit_failure_is_transactional", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + MC_OUTBOX]
        mov     rsi, 5
        call    af_buf_init
        AF_CHECK_OK rax, "small outbox init"
        mov     qword [rsp + MC_STDIN_FD], -1
        or      qword [rsp + MC_FLAGS], AF_MC_F_STDIN_OPEN

        lea     rdi, [rsp + MC_OUTBOX]
        lea     rsi, [send_seed_byte]
        mov     rdx, 1
        call    af_buf_append
        AF_CHECK_OK rax, "seed the existing outbox"
        lea     rdi, [rsp]
        lea     rsi, [send_line_four]
        mov     rdx, 4
        call    af_mcp_send
        AF_CHECK_ERR rax, AF_E_LIMIT, "line plus LF must be checked as one bounded append"
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_len
        AF_CHECK_EQ rax, 1, "a refused LF leaves the previous outbox exact"
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_data
        mov     rbx, rax
        lea     r12, [send_seed_byte]
        AF_CHECK_MEM_EQ rbx, r12, 1, "a refused frame does not overwrite queued bytes"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_OUT], 0, "a refused frame is not counted"

        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/frame/send_newline_allocation_failure_is_transactional", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + MC_OUTBOX]
        mov     rsi, 65
        call    af_buf_init
        AF_CHECK_OK rax, "growth-boundary outbox init"
        mov     qword [rsp + MC_STDIN_FD], -1
        or      qword [rsp + MC_FLAGS], AF_MC_F_STDIN_OPEN

        lea     rdi, [rsp + MC_OUTBOX]
        lea     rsi, [send_seed_63]
        mov     rdx, 63
        call    af_buf_append
        AF_CHECK_OK rax, "seed one byte below the first allocation capacity"
        call    af_alloc_reset_counters
        mov     rdi, 1
        call    af_alloc_inject_failure_at
        lea     rdi, [rsp]
        lea     rsi, [send_seed_byte]
        mov     rdx, 1
        call    af_mcp_send
        AF_CHECK_ERR rax, AF_E_NOMEM, "reserving line plus LF reports allocation failure"
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_len
        AF_CHECK_EQ rax, 63, "failed LF growth leaves no unterminated payload byte"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_OUT], 0, "an allocation-failed frame is not counted"
        call    af_alloc_reset_counters

        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_free
        AF_TEST_END

; ---------------------------------------------------------------------------
; JSON-RPC call table and response correlation.
; ---------------------------------------------------------------------------

        AF_TEST "mcp/rpc/call_allocation_preserves_kind_and_deadline", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        mov     rdx, 123456789
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "the first call slot is allocated"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_PENDING, "the call starts pending"
        AF_CHECK_EQ qword [rbx + CL_ID], 1, "the first process-local id is one"
        AF_CHECK_EQ qword [rbx + CL_KIND], AF_MCP_CALL_TOOLS, "the call kind is preserved"
        AF_CHECK_EQ qword [rbx + CL_DEADLINE], 123456789, "the deadline is preserved"

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_PROMPTS
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     r12, rax
        AF_CHECK_NE r12, 0, "the second call slot is allocated"
        AF_CHECK_EQ qword [r12 + CL_ID], 2, "ids increase within one process"
        AF_CHECK_EQ qword [r12 + CL_KIND], AF_MCP_CALL_PROMPTS, "a second kind is independent"
        AF_CHECK_EQ qword [r12 + CL_DEADLINE], 0, "zero means no deadline"
        AF_CHECK_EQ qword [rbx + CL_KIND], AF_MCP_CALL_TOOLS, "allocating another call does not rewrite the first"
        AF_CHECK_EQ qword [rbx + CL_DEADLINE], 123456789, "the first deadline remains intact"

        lea     rdi, [rsp]
        call    af_mcp_calls_release
        AF_TEST_END

        AF_TEST "mcp/rpc/request_preserves_kind_and_timeout_across_clock_read", 2304
%define RQP_PIPE ((MC_SIZE + 15) & ~15)
AF_STATIC_ASSERT RQP_PIPE >= MC_SIZE, "request pipe overlaps af_mcp_child"
AF_STATIC_ASSERT (RQP_PIPE + 8) <= 2304, "request fixture exceeds its stack frame"
        lea     rdi, [rsp]
        mov     rsi, RQP_PIPE + 8
        call    af_mem_zero
        lea     rdi, [rsp + MC_OUTBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "outbox init"

        lea     rdi, [rsp + RQP_PIPE]
        mov     rsi, O_NONBLOCK | O_CLOEXEC
        call    af_sys_pipe2
        AF_CHECK_OK rax, "nonblocking request pipe"
        mov     r12d, [rsp + RQP_PIPE + AF_PIPE_READ * 4]
        mov     r13d, [rsp + RQP_PIPE + AF_PIPE_WRITE * 4]
        mov     [rsp + MC_STDIN_FD], r13
        or      qword [rsp + MC_FLAGS], AF_MC_F_STDIN_OPEN

        mov     rdi, 5000000
        call    af_clock_set_override_ns
        lea     rdi, [rsp]
        lea     rsi, [request_method]
        xor     edx, edx
        mov     rcx, AF_MCP_CALL_RESOURCES
        mov     r8, 250
        call    af_mcp_request
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "the request is queued through the pipe"
        AF_CHECK_EQ qword [rbx + CL_KIND], AF_MCP_CALL_RESOURCES, "the fourth argument survives the clock call"
        AF_CHECK_EQ qword [rbx + CL_DEADLINE], 255000000, "deadline is override plus the requested timeout"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_OUT], 1, "one JSON-RPC frame was written"

        mov     rdi, -1
        call    af_clock_set_override_ns
        lea     rdi, [rsp]
        call    af_mcp_calls_release
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_free
        mov     rdi, r12
        call    af_sys_close
        mov     rdi, r13
        call    af_sys_close
        AF_TEST_END

        AF_TEST "mcp/rpc/a_response_completes_only_its_matching_call", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_FRAME_MAX], 1024

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        mov     rdx, 999999
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "the request call exists"

        lea     rdi, [rsp]
        lea     rsi, [json_response]
        mov     rdx, json_response_len
        call    af_mcp_on_message
        AF_CHECK_OK rax, "the matching response is accepted"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_DONE, "the matching call completes"
        AF_CHECK_OK qword [rbx + CL_STATUS], "a result completes successfully"
        AF_CHECK_EQ qword [rbx + CL_KIND], AF_MCP_CALL_TOOLS, "response handling preserves the call kind"
        AF_CHECK_EQ qword [rbx + CL_DEADLINE], 999999, "response handling preserves the deadline"
        AF_CHECK_EQ qword [rsp + MC_UNMATCHED], 0, "the known id is not unmatched"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 0, "a valid result is not contamination"

        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_len
        AF_CHECK_EQ rax, json_result_len, "only the result member is stored"
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_data
        mov     r12, rax
        lea     r13, [json_result]
        AF_CHECK_MEM_EQ r12, r13, json_result_len, "the stored result retains its JSON meaning"

        lea     rdi, [rsp]
        lea     rsi, [json_response_duplicate]
        mov     rdx, json_response_duplicate_len
        call    af_mcp_on_message
        AF_CHECK_OK rax, "a duplicate response is isolated without changing the completed call"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_DONE, "the duplicate leaves the call done"
        AF_CHECK_OK qword [rbx + CL_STATUS], "the duplicate cannot overwrite the original status"
        AF_CHECK_EQ qword [rsp + MC_UNMATCHED], 1, "a duplicate response is counted unmatched"
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_len
        AF_CHECK_EQ rax, json_result_len, "the duplicate cannot replace the original result"
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_data
        mov     r12, rax
        lea     r13, [json_result]
        AF_CHECK_MEM_EQ r12, r13, json_result_len, "the original result remains exact after a duplicate"

        lea     rdi, [rsp]
        call    af_mcp_calls_release
        AF_TEST_END

        AF_TEST "mcp/rpc/response_shape_is_exclusive_and_has_no_method", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_FRAME_MAX], 1024

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "the strict-shape call exists"

        lea     rdi, [rsp]
        lea     rsi, [json_response_both]
        mov     rdx, json_response_both_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "result and error together contaminate the session"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_PENDING, "an ambiguous response cannot complete its call"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 1, "the ambiguous response is counted as contamination"
        AF_CHECK_EQ qword [rsp + MC_UNMATCHED], 0, "shape corruption is not reported as an unmatched id"

        lea     rdi, [rsp]
        lea     rsi, [json_response_with_method]
        mov     rdx, json_response_with_method_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "a response carrying method contaminates the session"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_PENDING, "a response/request hybrid cannot complete its call"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 2, "the hybrid is counted as contamination"
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "malformed response shapes store no result"

        lea     rdi, [rsp]
        call    af_mcp_calls_release
        AF_TEST_END

        AF_TEST "mcp/rpc/server_requests_with_integer_or_string_ids_are_recorded", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_FRAME_MAX], 1024
        mov     qword [rsp + MC_STATE], AF_MCP_S_READY

        lea     rdi, [rsp]
        lea     rsi, [json_request_integer_id]
        mov     rdx, json_request_integer_id_len
        call    af_mcp_on_message
        AF_CHECK_OK rax, "integer-id server request is a supported request shape"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 1, "integer-id server request is recorded and unanswered"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 0, "integer-id server request does not contaminate the session"
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_READY, "recording the request leaves readiness intact"

        lea     rdi, [rsp]
        lea     rsi, [json_request_string_id]
        mov     rdx, json_request_string_id_len
        call    af_mcp_on_message
        AF_CHECK_OK rax, "string-id server request is also recorded"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 2, "both server requests are counted"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 0, "string-id server request does not contaminate the session"
        AF_TEST_END

        AF_TEST "mcp/rpc/server_request_id_and_params_types_are_strict", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_FRAME_MAX], 1024
        mov     qword [rsp + MC_STATE], AF_MCP_S_READY

        lea     rdi, [rsp]
        lea     rsi, [json_request_null_id_array_params]
        mov     rdx, json_request_null_id_array_params_len
        call    af_mcp_on_message
        AF_CHECK_OK rax, "null request id and array params remain interoperable"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 1, "valid structured request is recorded"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 0, "valid null id is not contamination"

        lea     rdi, [rsp]
        lea     rsi, [json_request_object_id]
        mov     rdx, json_request_object_id_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "object request id contaminates the session"
        lea     rdi, [rsp]
        lea     rsi, [json_request_array_id]
        mov     rdx, json_request_array_id_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "array request id contaminates the session"
        lea     rdi, [rsp]
        lea     rsi, [json_request_bool_id]
        mov     rdx, json_request_bool_id_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "boolean request id contaminates the session"
        lea     rdi, [rsp]
        lea     rsi, [json_request_real_id]
        mov     rdx, json_request_real_id_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "real request id contaminates the session"
        lea     rdi, [rsp]
        lea     rsi, [json_request_scalar_params]
        mov     rdx, json_request_scalar_params_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "scalar request params contaminate the session"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 5, "every invalid request type is counted exactly once"
        AF_CHECK_EQ qword [rsp + MC_NOTIFICATIONS], 1, "invalid requests are never recorded as accepted"
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_READY, "parser classification alone does not mutate child state"
        AF_TEST_END

        AF_TEST "mcp/rpc/error_response_requires_object_code_and_message", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_FRAME_MAX], 1024
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "the error-response call exists"

        lea     rdi, [rsp]
        lea     rsi, [json_error_scalar]
        mov     rdx, json_error_scalar_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "scalar error is protocol contamination"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_PENDING, "scalar error cannot complete the call"

        lea     rdi, [rsp]
        lea     rsi, [json_error_missing_code]
        mov     rdx, json_error_missing_code_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "error without integer code is rejected"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_PENDING, "missing code cannot complete the call"

        lea     rdi, [rsp]
        lea     rsi, [json_error_missing_message]
        mov     rdx, json_error_missing_message_len
        call    af_mcp_on_message
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "error without string message is rejected"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_PENDING, "missing message cannot complete the call"
        AF_CHECK_EQ qword [rsp + MC_CONTAMINATED], 3, "each malformed error is counted"

        lea     rdi, [rsp]
        lea     rsi, [json_error_valid]
        mov     rdx, json_error_valid_len
        call    af_mcp_on_message
        AF_CHECK_OK rax, "well-formed JSON-RPC error correlates"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_DONE, "valid error completes the call"
        AF_CHECK_ERR qword [rbx + CL_STATUS], AF_E_MCP_PROTOCOL, "remote error records protocol status"
        AF_CHECK_EQ qword [rbx + CL_ERROR_CODE], -32001, "remote integer error code is retained"

        lea     rdi, [rsp]
        call    af_mcp_calls_release
        AF_TEST_END

        AF_TEST "mcp/rpc/a_late_response_cannot_complete_a_timed_out_call", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_FRAME_MAX], 1024
        mov     qword [rsp + MC_ERA], AF_ERA_MODERN
        mov     qword [rsp + MC_STDIN_FD], -1
        or      qword [rsp + MC_FLAGS], AF_MC_F_STDIN_OPEN
        lea     rdi, [rsp + MC_OUTBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "modern cancellation outbox init"

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        mov     rdx, 100
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "the expiring call exists"
        lea     rdi, [rsp]
        mov     rsi, 100
        call    af_mcp_sweep_calls
        AF_CHECK_EQ rax, 1, "the deadline sweep completes one call"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_DONE, "the expired call is done"
        AF_CHECK_ERR qword [rbx + CL_STATUS], AF_E_MCP_TIMEOUT, "the expired call records timeout"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_OUT], 1, "modern timeout emits one cancellation notification"
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_len
        AF_CHECK_EQ rax, json_cancelled_one_len, "modern cancellation has the exact bounded frame length"
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_data
        lea     r12, [json_cancelled_one]
        AF_CHECK_MEM_EQ rax, r12, json_cancelled_one_len, "modern tool timeout emits notifications/cancelled without id or _meta"

        lea     rdi, [rsp]
        lea     rsi, [json_response]
        mov     rdx, json_response_len
        call    af_mcp_on_message
        AF_CHECK_OK rax, "a late response is isolated"
        AF_CHECK_EQ qword [rsp + MC_UNMATCHED], 1, "a late response is counted unmatched"
        AF_CHECK_ERR qword [rbx + CL_STATUS], AF_E_MCP_TIMEOUT, "the late response cannot erase timeout"
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "the late response cannot install a result"

        lea     rdi, [rsp]
        call    af_mcp_calls_release
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/rpc/cancellation_adapters_cover_discover_legacy_and_initialize", 2304
        ; Discovery is modern before era selection has been committed.
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_STDIN_FD], -1
        or      qword [rsp + MC_FLAGS], AF_MC_F_STDIN_OPEN
        lea     rdi, [rsp + MC_OUTBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "discover cancellation outbox init"
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_DISCOVER
        mov     rdx, 100
        call    af_mcp_call_alloc
        mov     rbx, rax
        lea     rdi, [rsp]
        mov     rsi, 100
        call    af_mcp_sweep_calls
        AF_CHECK_EQ rax, 1, "modern discovery timeout is retired"
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_data
        lea     r12, [json_cancelled_one]
        AF_CHECK_MEM_EQ rax, r12, json_cancelled_one_len, "discovery timeout uses the modern cancellation adapter"
        lea     rdi, [rsp]
        call    af_mcp_calls_release
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_free

        ; Legacy non-task requests use the isolated legacy adapter and the
        ; same currently specified stdio wire shape.
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_ERA], AF_ERA_LEGACY
        mov     qword [rsp + MC_STDIN_FD], -1
        or      qword [rsp + MC_FLAGS], AF_MC_F_STDIN_OPEN
        lea     rdi, [rsp + MC_OUTBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "legacy cancellation outbox init"
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOL_TEST
        mov     rdx, 100
        call    af_mcp_call_alloc
        mov     rbx, rax
        lea     rdi, [rsp]
        mov     rsi, 100
        call    af_mcp_sweep_calls
        AF_CHECK_EQ rax, 1, "legacy tool timeout is retired"
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_data
        lea     r12, [json_cancelled_one]
        AF_CHECK_MEM_EQ rax, r12, json_cancelled_one_len, "legacy tool timeout emits the same specified cancellation frame"
        lea     rdi, [rsp]
        call    af_mcp_calls_release
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_free

        ; The legacy initialize handshake is explicitly exempt: it is not a
        ; running non-task request and must not receive cancellation.
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_ERA], AF_ERA_LEGACY
        mov     qword [rsp + MC_STDIN_FD], -1
        or      qword [rsp + MC_FLAGS], AF_MC_F_STDIN_OPEN
        lea     rdi, [rsp + MC_OUTBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "legacy initialize outbox init"
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_INITIALIZE
        mov     rdx, 100
        call    af_mcp_call_alloc
        mov     rbx, rax
        lea     rdi, [rsp]
        mov     rsi, 100
        call    af_mcp_sweep_calls
        AF_CHECK_EQ rax, 1, "legacy initialize timeout is retired locally"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_DONE, "initialize timeout completes locally"
        AF_CHECK_ERR qword [rbx + CL_STATUS], AF_E_MCP_TIMEOUT, "initialize records timeout"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_OUT], 0, "legacy initialize timeout emits no cancellation"
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "initialize exception leaves the outbox empty"
        lea     rdi, [rsp]
        call    af_mcp_calls_release
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/era/completed_modern_error_falls_back_in_same_process", 2560
%define ER_CFG ((MC_SIZE + 15) & ~15)
AF_STATIC_ASSERT (ER_CFG + MCP_SIZE) <= 2560, "era fallback fixture exceeds its stack frame"
        lea     rdi, [rsp]
        mov     rsi, ER_CFG + MCP_SIZE
        call    af_mem_zero
        lea     rax, [rsp + ER_CFG]
        mov     [rsp + MC_CFG], rax
        mov     qword [rsp + ER_CFG + MCP_PROTO_LEGACY], AF_MCP_LEGACY_2025_11_25
        mov     qword [rsp + ER_CFG + MCP_STARTUP_TIMEOUT], 1000
        mov     qword [rsp + MC_STATE], AF_MCP_S_PROBING
        mov     qword [rsp + MC_STDIN_FD], -1
        or      qword [rsp + MC_FLAGS], AF_MC_F_STDIN_OPEN
        lea     rdi, [rsp + MC_OUTBOX]
        mov     rsi, 4096
        call    af_buf_init
        AF_CHECK_OK rax, "same-process fallback outbox init"

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_DISCOVER
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "completed discover call exists"
        mov     qword [rbx + CL_STATUS], AF_E_MCP_PROTOCOL
        mov     qword [rbx + CL_STATE], AF_MCP_CALL_DONE
        lea     rdi, [rsp]
        call    af_mcp_advance

        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_PROBING, "completed refusal stays in the same probing process"
        mov     r12, [rsp + MC_FLAGS]
        and     r12, (AF_MC_F_LEGACY_NEXT | AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP)
        AF_CHECK_EQ r12, 0, "completed refusal does not arm the fresh-process timeout switch"
        AF_CHECK_EQ qword [rsp + MC_CALLS + CL_STATE], AF_MCP_CALL_PENDING, "legacy initialize replaces the completed discover call"
        AF_CHECK_EQ qword [rsp + MC_CALLS + CL_KIND], AF_MCP_CALL_INITIALIZE, "same-process fallback queues only legacy initialize"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_OUT], 1, "same-process fallback emits one initialize frame"

        lea     rdi, [rsp]
        call    af_mcp_calls_release
        lea     rdi, [rsp + MC_OUTBOX]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/rpc/cancellation_emission_failure_stops_the_child", 2560
%define CF_CFG ((MC_SIZE + 15) & ~15)
AF_STATIC_ASSERT (CF_CFG + MCP_SIZE) <= 2560, "cancellation failure fixture exceeds its stack frame"
        lea     rdi, [rsp]
        mov     rsi, CF_CFG + MCP_SIZE
        call    af_mem_zero
        lea     rax, [rsp + CF_CFG]
        mov     [rsp + MC_CFG], rax
        mov     qword [rsp + CF_CFG + MCP_RESTART_MODE], AF_RESTART_NEVER
        mov     qword [rsp + MC_STATE], AF_MCP_S_READY
        mov     qword [rsp + MC_STARTS], 1
        mov     qword [rsp + MC_ERA], AF_ERA_MODERN
        mov     qword [rsp + MC_STDIN_FD], -1
        ; No STDIN_OPEN: encoding succeeds, but transactional send reports
        ; AF_E_CLOSED and the supervisor must not leave the child usable.
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        mov     rdx, 100
        call    af_mcp_call_alloc
        AF_CHECK_NE rax, 0, "the cancellation-failure call exists"
        lea     rdi, [rsp]
        xor     esi, esi
        mov     rdx, 100
        call    af_mcp_sweep_child
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_FAILED, "cancellation transport failure stops a mode=never child"
        mov     rbx, [rsp + MC_FLAGS]
        and     rbx, AF_MC_F_PROCESS_FAILURE
        AF_CHECK_TRUE rbx, "cancellation transport failure records a process failure cause"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_OUT], 0, "failed cancellation increments no output frame counter"
        AF_CHECK_EQ qword [rsp + MC_CALLS + CL_STATE], AF_MCP_CALL_FREE, "failure invalidation releases the retired timeout call"
        AF_TEST_END

        AF_TEST "mcp/supervisor/tick_uses_one_child_stride_for_every_entry", 128
        mov     rdi, MS_SIZE
        call    af_alloc
        mov     r12, rax
        AF_CHECK_NE r12, 0, "bounded supervisor fixture allocation"
        mov     rdi, r12
        mov     rsi, MS_SIZE
        call    af_mem_zero
        mov     qword [r12 + MS_TIMER_FD], -1
        mov     qword [r12 + MS_COUNT], 2
        lea     r13, [r12 + MS_CHILDREN]
        lea     r14, [r13 + MC_SIZE]
        mov     qword [r13 + MC_STATE], AF_MCP_S_STOPPED
        mov     qword [r13 + MC_STARTS], 1
        mov     qword [r14 + MC_STATE], AF_MCP_S_STOPPED
        mov     qword [r14 + MC_STARTS], 1
        mov     rdi, r13
        mov     rsi, AF_MCP_CALL_INITIALIZE
        mov     rdx, 1
        call    af_mcp_call_alloc
        mov     rbx, rax
        mov     rdi, r14
        mov     rsi, AF_MCP_CALL_INITIALIZE
        mov     rdx, 1
        call    af_mcp_call_alloc
        mov     r15, rax
        AF_CHECK_NE rbx, 0, "first child timeout call exists"
        AF_CHECK_NE r15, 0, "second child timeout call exists"
        mov     rdi, 100
        call    af_clock_set_override_ns
        mov     rdi, r12
        xor     esi, esi
        xor     edx, edx
        call    af_mcp_on_tick
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_DONE, "tick advances the first child"
        AF_CHECK_EQ qword [r15 + CL_STATE], AF_MCP_CALL_DONE, "tick advances the adjacent second child at exactly MC_SIZE"
        AF_CHECK_ERR qword [rbx + CL_STATUS], AF_E_MCP_TIMEOUT, "first child records timeout"
        AF_CHECK_ERR qword [r15 + CL_STATUS], AF_E_MCP_TIMEOUT, "second child records timeout"
        mov     rdi, -1
        call    af_clock_set_override_ns
        mov     rdi, r13
        call    af_mcp_calls_release
        mov     rdi, r14
        call    af_mcp_calls_release
        mov     rdi, r12
        call    af_free
        AF_TEST_END

        AF_TEST "mcp/rpc/result_limit_failure_completes_with_no_stale_result", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_FRAME_MAX], 1024

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "the bounded-result call exists"
        mov     qword [rbx + CL_RESULT + TEST_BUF_MAX], stale_result_len
        lea     rdi, [rbx + CL_RESULT]
        lea     rsi, [stale_result]
        mov     rdx, stale_result_len
        call    af_buf_append
        AF_CHECK_OK rax, "seed a prior result inside the reduced ceiling"

        lea     rdi, [rsp]
        lea     rsi, [json_response]
        mov     rdx, json_response_len
        call    af_mcp_on_message
        AF_CHECK_OK rax, "the matched response is consumed despite local storage failure"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_DONE, "storage failure still completes the call"
        AF_CHECK_ERR qword [rbx + CL_STATUS], AF_E_LIMIT, "result ceiling failure is propagated"
        AF_CHECK_EQ qword [rsp + MC_UNMATCHED], 0, "the matched response is not unmatched"
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "storage failure exposes neither stale nor partial result bytes"

        lea     rdi, [rsp]
        call    af_mcp_calls_release
        AF_TEST_END

        AF_TEST "mcp/rpc/result_allocation_failure_is_the_call_status", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_FRAME_MAX], 1024

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "the allocation-failure call exists"
        call    af_alloc_reset_counters
        ; af_json_parse owns the first wrapper allocation (its bounded error
        ; record); the result buffer growth is the second.
        mov     rdi, 2
        call    af_alloc_inject_failure_at
        lea     rdi, [rsp]
        lea     rsi, [json_response]
        mov     rdx, json_response_len
        call    af_mcp_on_message
        AF_CHECK_OK rax, "the matched response is consumed after allocation failure"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_DONE, "allocation failure completes the call"
        AF_CHECK_ERR qword [rbx + CL_STATUS], AF_E_NOMEM, "result allocation failure is propagated"
        lea     rdi, [rbx + CL_RESULT]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "allocation failure leaves no partial result"
        call    af_alloc_reset_counters

        lea     rdi, [rsp]
        call    af_mcp_calls_release
        AF_TEST_END

; ---------------------------------------------------------------------------
; Supervisor process-view and inventory state.
; ---------------------------------------------------------------------------

        AF_TEST "mcp/inventory/refresh_failure_degrades_a_ready_child", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_STATE], AF_MCP_S_READY
        mov     qword [rsp + MC_ERA], AF_ERA_UNKNOWN
        or      qword [rsp + MC_FLAGS], AF_MC_F_TOOLS_CURRENT

        lea     rdi, [rsp]
        call    af_mcp_refresh_inventory
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "inventory begin returns its original protocol error"
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_DEGRADED, "a failed refresh cannot leave the child ready"
        mov     rbx, [rsp + MC_FLAGS]
        and     rbx, AF_MC_F_TOOLS_CURRENT
        AF_CHECK_EQ rbx, 0, "a failed refresh invalidates current inventory readiness"
        AF_TEST_END

        AF_TEST "mcp/inventory/repeated_refresh_waits_for_pending_batch_atomically", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_STATE], AF_MCP_S_READY
        mov     qword [rsp + MC_ERA], AF_ERA_MODERN
        or      qword [rsp + MC_FLAGS], (AF_MC_F_LISTED | AF_MC_F_TOOLS_CURRENT)

        ; Put a DONE inventory call before a PENDING one. A one-pass release
        ; would partially destroy the old batch before discovering it must wait.
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_RESOURCES
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        mov     qword [rbx + CL_STATE], AF_MCP_CALL_DONE
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        mov     rdx, 1000
        call    af_mcp_call_alloc
        mov     r12, rax

        lea     rdi, [rsp]
        call    af_mcp_refresh_inventory
        AF_CHECK_ERR rax, AF_E_MCP_NOT_READY, "refresh waits while any inventory request is pending"
        AF_CHECK_EQ qword [rbx + CL_STATE], AF_MCP_CALL_DONE, "atomic wait preserves an earlier completed list call"
        AF_CHECK_EQ qword [r12 + CL_STATE], AF_MCP_CALL_PENDING, "atomic wait preserves the remote pending call"
        AF_CHECK_EQ qword [rsp + MC_NEXT_ID], 2, "repeated refresh emits no duplicate inventory requests"
        AF_CHECK_EQ qword [rsp + MC_FRAMES_OUT], 0, "wait policy emits neither duplicate request nor cancellation"
        mov     r13, [rsp + MC_FLAGS]
        and     r13, (AF_MC_F_LISTED | AF_MC_F_TOOLS_CURRENT)
        AF_CHECK_EQ r13, (AF_MC_F_LISTED | AF_MC_F_TOOLS_CURRENT), "waiting preserves committed readiness state"

        lea     rdi, [rsp]
        call    af_mcp_calls_release
        AF_TEST_END

        AF_TEST "mcp/inventory/semantic_tool_items_gate_required_readiness", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_STATE], AF_MCP_S_READY
        or      qword [rsp + MC_FLAGS], AF_MC_F_TOOLS_CURRENT
        lea     rdi, [rsp + MC_TOOLS]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        AF_CHECK_OK rax, "initialize prior required tools cache"
        lea     rdi, [rsp + MC_TOOLS]
        lea     rsi, [inventory_old_tools]
        mov     rdx, inventory_old_tools_len
        call    af_buf_append
        AF_CHECK_OK rax, "seed prior required tools cache"
        mov     qword [rsp + MC_TOOL_COUNT], 1

        ; A scalar element is never a tool object.
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "allocate scalar tools result call"
        lea     rdi, [rbx + CL_RESULT]
        lea     rsi, [inventory_tools_scalar]
        mov     rdx, inventory_tools_scalar_len
        call    af_buf_append
        AF_CHECK_OK rax, "store scalar tools result"
        mov     qword [rbx + CL_STATE], AF_MCP_CALL_DONE
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        lea     rdx, [rsp + MC_TOOLS]
        lea     rcx, [rsp + MC_TOOL_COUNT]
        call    af_mcp_collect_list
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_DEGRADED, "scalar required tool degrades readiness"
        mov     rbx, [rsp + MC_FLAGS]
        and     rbx, AF_MC_F_TOOLS_CURRENT
        AF_CHECK_EQ rbx, 0, "scalar required tool is never current"

        ; An object without the required semantic members is equally invalid.
        mov     qword [rsp + MC_STATE], AF_MCP_S_READY
        or      qword [rsp + MC_FLAGS], AF_MC_F_TOOLS_CURRENT
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "allocate empty tools object call"
        lea     rdi, [rbx + CL_RESULT]
        lea     rsi, [inventory_tools_empty]
        mov     rdx, inventory_tools_empty_len
        call    af_buf_append
        AF_CHECK_OK rax, "store empty tools object result"
        mov     qword [rbx + CL_STATE], AF_MCP_CALL_DONE
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        lea     rdx, [rsp + MC_TOOLS]
        lea     rcx, [rsp + MC_TOOL_COUNT]
        call    af_mcp_collect_list
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_DEGRADED, "missing tool members degrade readiness"

        ; inputSchema is a schema object, never an arbitrary JSON value.
        mov     qword [rsp + MC_STATE], AF_MCP_S_READY
        or      qword [rsp + MC_FLAGS], AF_MC_F_TOOLS_CURRENT
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "allocate wrong inputSchema call"
        lea     rdi, [rbx + CL_RESULT]
        lea     rsi, [inventory_tools_bad_schema]
        mov     rdx, inventory_tools_bad_schema_len
        call    af_buf_append
        AF_CHECK_OK rax, "store wrong inputSchema result"
        mov     qword [rbx + CL_STATE], AF_MCP_CALL_DONE
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        lea     rdx, [rsp + MC_TOOLS]
        lea     rcx, [rsp + MC_TOOL_COUNT]
        call    af_mcp_collect_list
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_DEGRADED, "non-object inputSchema degrades readiness"
        AF_CHECK_EQ qword [rsp + MC_TOOL_COUNT], 1, "invalid required batch preserves the prior count"
        lea     rdi, [rsp + MC_TOOLS]
        call    af_buf_len
        AF_CHECK_EQ rax, inventory_old_tools_len, "invalid required batch preserves prior bytes"
        lea     rdi, [rsp + MC_TOOLS]
        call    af_buf_data
        mov     rbx, rax
        lea     r12, [inventory_old_tools]
        AF_CHECK_MEM_EQ rbx, r12, inventory_old_tools_len, "invalid required cache replacement is transactional"

        ; A valid semantic tool replaces the cache and restores readiness.
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "allocate valid tools result call"
        lea     rdi, [rbx + CL_RESULT]
        lea     rsi, [inventory_tools_valid]
        mov     rdx, inventory_tools_valid_len
        call    af_buf_append
        AF_CHECK_OK rax, "store valid tools result"
        mov     qword [rbx + CL_STATE], AF_MCP_CALL_DONE
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_TOOLS
        lea     rdx, [rsp + MC_TOOLS]
        lea     rcx, [rsp + MC_TOOL_COUNT]
        call    af_mcp_collect_list
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_READY, "validated tools restore required readiness"
        mov     rbx, [rsp + MC_FLAGS]
        and     rbx, AF_MC_F_TOOLS_CURRENT
        AF_CHECK_NE rbx, 0, "validated tools mark the required batch current"
        AF_CHECK_EQ qword [rsp + MC_TOOL_COUNT], 1, "validated tools commit their count"
        lea     rdi, [rsp + MC_TOOLS]
        call    af_buf_len
        AF_CHECK_EQ rax, inventory_tools_valid_cache_len, "validated tools commit only the compact array"
        lea     rdi, [rsp + MC_TOOLS]
        call    af_buf_data
        mov     rbx, rax
        lea     r12, [inventory_tools_valid_cache]
        AF_CHECK_MEM_EQ rbx, r12, inventory_tools_valid_cache_len, "validated tools cache preserves semantic content"

        lea     rdi, [rsp + MC_TOOLS]
        call    af_buf_free
        lea     rdi, [rsp]
        call    af_mcp_calls_release
        AF_TEST_END

        AF_TEST "mcp/inventory/invalid_optional_items_preserve_stale_caches", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_STATE], AF_MCP_S_READY
        or      qword [rsp + MC_FLAGS], AF_MC_F_TOOLS_CURRENT
        lea     rdi, [rsp + MC_RESOURCES]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        AF_CHECK_OK rax, "initialize prior resources cache"
        lea     rdi, [rsp + MC_RESOURCES]
        lea     rsi, [inventory_old_resources]
        mov     rdx, inventory_old_resources_len
        call    af_buf_append
        AF_CHECK_OK rax, "seed prior resources cache"
        mov     qword [rsp + MC_RES_COUNT], 1
        lea     rdi, [rsp + MC_PROMPTS]
        mov     rsi, AF_MCP_INVENTORY_MAX
        call    af_buf_init
        AF_CHECK_OK rax, "initialize prior prompts cache"
        lea     rdi, [rsp + MC_PROMPTS]
        lea     rsi, [inventory_old_prompts]
        mov     rdx, inventory_old_prompts_len
        call    af_buf_append
        AF_CHECK_OK rax, "seed prior prompts cache"
        mov     qword [rsp + MC_PROMPT_COUNT], 1

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_RESOURCES
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "allocate invalid resources result call"
        lea     rdi, [rbx + CL_RESULT]
        lea     rsi, [inventory_resources_missing_uri]
        mov     rdx, inventory_resources_missing_uri_len
        call    af_buf_append
        AF_CHECK_OK rax, "store resource missing URI"
        mov     qword [rbx + CL_STATE], AF_MCP_CALL_DONE

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_PROMPTS
        xor     edx, edx
        call    af_mcp_call_alloc
        mov     r12, rax
        AF_CHECK_NE r12, 0, "allocate invalid prompts result call"
        lea     rdi, [r12 + CL_RESULT]
        lea     rsi, [inventory_prompts_empty_name]
        mov     rdx, inventory_prompts_empty_name_len
        call    af_buf_append
        AF_CHECK_OK rax, "store prompt with empty name"
        mov     qword [r12 + CL_STATE], AF_MCP_CALL_DONE

        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_RESOURCES
        lea     rdx, [rsp + MC_RESOURCES]
        lea     rcx, [rsp + MC_RES_COUNT]
        call    af_mcp_collect_list
        lea     rdi, [rsp]
        mov     rsi, AF_MCP_CALL_PROMPTS
        lea     rdx, [rsp + MC_PROMPTS]
        lea     rcx, [rsp + MC_PROMPT_COUNT]
        call    af_mcp_collect_list

        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_READY, "optional semantic failures preserve ready tools"
        mov     rbx, [rsp + MC_FLAGS]
        and     rbx, AF_MC_F_TOOLS_CURRENT
        AF_CHECK_NE rbx, 0, "optional semantic failures preserve required readiness"
        AF_CHECK_EQ qword [rsp + MC_RES_COUNT], 1, "invalid resources preserve the stale count"
        AF_CHECK_EQ qword [rsp + MC_PROMPT_COUNT], 1, "invalid prompts preserve the stale count"
        lea     rdi, [rsp + MC_RESOURCES]
        call    af_buf_len
        AF_CHECK_EQ rax, inventory_old_resources_len, "invalid resources preserve stale bytes"
        lea     rdi, [rsp + MC_PROMPTS]
        call    af_buf_len
        AF_CHECK_EQ rax, inventory_old_prompts_len, "invalid prompts preserve stale bytes"

        lea     rdi, [rsp + MC_RESOURCES]
        call    af_buf_free
        lea     rdi, [rsp + MC_PROMPTS]
        call    af_buf_free
        lea     rdi, [rsp]
        call    af_mcp_calls_release
        AF_TEST_END

        AF_TEST "mcp/supervisor/failure_invalidates_the_negotiated_process_view", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        mov     qword [rsp + MC_STATE], AF_MCP_S_READY
        mov     qword [rsp + MC_ERA], AF_ERA_MODERN
        mov     qword [rsp + MC_SCAN_CURSOR], 17
        or      qword [rsp + MC_FLAGS], (AF_MC_F_MANUAL_STOP | AF_MC_F_PROBED | AF_MC_F_LISTED | AF_MC_F_TOOLS_CURRENT)
        mov     rdi, 16
        call    af_alloc
        AF_CHECK_NE rax, 0, "allocate an owned negotiated version"
        mov     [rsp + MC_VERSION], rax

        lea     rdi, [rsp]
        mov     rsi, AF_E_MCP_PROTOCOL
        call    af_mcp_child_failed
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_FAILED, "failure leaves the child failed"
        AF_CHECK_EQ qword [rsp + MC_ERA], AF_ERA_UNKNOWN, "failure invalidates the negotiated era"
        AF_CHECK_EQ qword [rsp + MC_VERSION], 0, "failure releases the owned negotiated version"
        AF_CHECK_EQ qword [rsp + MC_SCAN_CURSOR], 0, "failure resets partial-frame scan state"
        mov     rbx, [rsp + MC_FLAGS]
        and     rbx, (AF_MC_F_PROBED | AF_MC_F_LISTED | AF_MC_F_TOOLS_CURRENT)
        AF_CHECK_EQ rbx, 0, "failure clears negotiated and inventory validity flags"
        mov     rbx, [rsp + MC_FLAGS]
        and     rbx, AF_MC_F_PROCESS_FAILURE
        AF_CHECK_TRUE rbx, "non-EOF failure cause survives process-view invalidation"
        AF_TEST_END

        AF_TEST "mcp/supervisor/terminal_latches_require_their_own_actions", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE + 16
        call    af_mem_zero
        mov     qword [rsp + MC_STATE], AF_MCP_S_DISABLED
        mov     qword [rsp + MC_RESTARTS], 7
        mov     qword [rsp + MC_BACKOFF_MS], 99

        lea     rdi, [rsp]
        xor     esi, esi
        mov     rdx, 1
        call    af_mcp_stop
        AF_CHECK_ERR rax, AF_E_MCP_NOT_READY, "stop rejects a disabled child"
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_DISABLED, "stop preserves the disabled latch"
        AF_CHECK_EQ qword [rsp + MC_PID], 0, "a disabled child remains unspawned"
        AF_CHECK_EQ qword [rsp + MC_RESTARTS], 7, "disabled stop does not alter restart accounting"

        lea     rdi, [rsp]
        call    af_mcp_reset
        AF_CHECK_ERR rax, AF_E_MCP_NOT_READY, "crash-loop reset rejects a disabled child"
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_DISABLED, "reset preserves the disabled latch"
        AF_CHECK_EQ qword [rsp + MC_BACKOFF_MS], 99, "rejected disabled reset preserves backoff"
        lea     rdi, [rsp]
        lea     rsi, [rsp + MC_SIZE]
        call    af_mcp_start
        AF_CHECK_ERR rax, AF_E_CLOSED, "start still rejects the disabled child after stop/reset"

        lea     rdi, [rsp]
        mov     rsi, MC_SIZE + 16
        call    af_mem_zero
        mov     qword [rsp + MC_STATE], AF_MCP_S_STOPPED
        mov     qword [rsp + MC_RESTARTS], 4
        mov     qword [rsp + MC_BACKOFF_MS], 33
        lea     rdi, [rsp]
        call    af_mcp_reset
        AF_CHECK_ERR rax, AF_E_MCP_NOT_READY, "crash-loop reset is not a start alias for stopped children"
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_STOPPED, "rejected reset preserves stopped state"
        AF_CHECK_EQ qword [rsp + MC_RESTARTS], 4, "rejected reset preserves a non-crash-loop budget"
        AF_CHECK_EQ qword [rsp + MC_BACKOFF_MS], 33, "rejected reset preserves a non-crash-loop backoff"

        lea     rdi, [rsp]
        mov     rsi, MC_SIZE + 16
        call    af_mem_zero
        mov     qword [rsp + MC_STATE], AF_MCP_S_CRASH_LOOP
        mov     qword [rsp + MC_RESTARTS], 3
        mov     qword [rsp + MC_BACKOFF_MS], 40
        mov     qword [rsp + MC_RESTART_HISTORY], 111
        mov     qword [rsp + MC_RESTART_HISTORY + 8], 222
        lea     rdi, [rsp]
        xor     esi, esi
        mov     rdx, 1
        call    af_mcp_stop
        AF_CHECK_ERR rax, AF_E_MCP_CRASH_LOOP, "stop rejects a crash-loop child"
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_CRASH_LOOP, "stop preserves the crash-loop latch"
        AF_CHECK_EQ qword [rsp + MC_RESTARTS], 3, "crash-loop stop preserves the exhausted budget"
        lea     rdi, [rsp]
        lea     rsi, [rsp + MC_SIZE]
        call    af_mcp_start
        AF_CHECK_ERR rax, AF_E_CLOSED, "start cannot bypass crash-loop through stop"
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_CRASH_LOOP, "failed start preserves crash-loop state"

        lea     rdi, [rsp]
        call    af_mcp_reset
        AF_CHECK_OK rax, "the dedicated reset action clears crash-loop"
        AF_CHECK_EQ qword [rsp + MC_STATE], AF_MCP_S_RESTARTING, "reset puts a crash-loop child on the restart path"
        AF_CHECK_EQ qword [rsp + MC_RESTARTS], 0, "reset clears the exhausted budget"
        AF_CHECK_EQ qword [rsp + MC_BACKOFF_MS], 0, "reset clears exponential backoff"
        AF_CHECK_EQ qword [rsp + MC_RESTART_HISTORY], 0, "reset clears restart history storage"
        AF_CHECK_EQ qword [rsp + MC_RESTART_HISTORY + 8], 0, "reset clears every retained timestamp"
        AF_TEST_END

; ---------------------------------------------------------------------------
; stderr bounds and restart budget.
; ---------------------------------------------------------------------------

        AF_TEST "mcp/stderr/a_long_line_is_truncated_and_counted_once", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + MC_ERRLINE]
        mov     rsi, 64
        call    af_buf_init
        AF_CHECK_OK rax, "stderr line buffer init"
        lea     rdi, [rsp + MC_ERRLOG]
        mov     rsi, AF_MCP_STDERR_KEEP
        call    af_buf_init
        AF_CHECK_OK rax, "stderr tail buffer init"
        mov     qword [rsp + MC_STDERR_MAX], 4

        lea     rdi, [rsp]
        lea     rsi, [stderr_long_line]
        mov     rdx, stderr_long_line_len
        call    af_mcp_capture_stderr
        AF_CHECK_EQ qword [rsp + MC_STDERR_TRUNC], 1, "one truncated line increments the counter once"
        lea     rdi, [rsp + MC_ERRLINE]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "a terminated stderr line leaves no partial bytes"
        lea     rdi, [rsp + MC_ERRLOG]
        call    af_buf_len
        AF_CHECK_EQ rax, stderr_kept_len, "the kept line is bounded plus newline"
        lea     rdi, [rsp + MC_ERRLOG]
        call    af_buf_data
        mov     rbx, rax
        lea     r12, [stderr_kept]
        AF_CHECK_MEM_EQ rbx, r12, stderr_kept_len, "stderr keeps the bounded prefix"

        lea     rdi, [rsp + MC_ERRLINE]
        call    af_buf_free
        lea     rdi, [rsp + MC_ERRLOG]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/stderr/an_oversized_kept_line_retains_its_exact_suffix", 2304
        lea     rdi, [rsp]
        mov     rsi, MC_SIZE
        call    af_mem_zero
        lea     rdi, [rsp + MC_ERRLINE]
        mov     rsi, 1024 * 1024
        call    af_buf_init
        AF_CHECK_OK rax, "large stderr line buffer init"
        lea     rdi, [rsp + MC_ERRLOG]
        mov     rsi, AF_MCP_STDERR_KEEP
        call    af_buf_init
        AF_CHECK_OK rax, "bounded stderr tail buffer init"

        lea     rdi, [rsp + MC_ERRLOG]
        lea     rsi, [stderr_previous]
        mov     rdx, stderr_previous_len
        call    af_buf_append
        AF_CHECK_OK rax, "seed the old stderr tail"
        lea     rdi, [rsp + MC_ERRLINE]
        lea     rsi, [stderr_over_keep_line]
        mov     rdx, stderr_over_keep_payload_len
        call    af_buf_append
        AF_CHECK_OK rax, "stage a configured stderr line larger than the kept tail"

        lea     rdi, [rsp]
        call    af_mcp_flush_errline
        lea     rdi, [rsp + MC_ERRLINE]
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "flushing clears the staged stderr line"
        lea     rdi, [rsp + MC_ERRLOG]
        call    af_buf_len
        AF_CHECK_EQ rax, AF_MCP_STDERR_KEEP, "stderr tail never exceeds its exact keep bound"
        lea     rdi, [rsp + MC_ERRLOG]
        call    af_buf_data
        mov     rbx, rax
        lea     r12, [stderr_over_keep_suffix]
        AF_CHECK_MEM_EQ rbx, r12, stderr_over_keep_expected_len, "stderr retains the newest line suffix and one newline"

        lea     rdi, [rsp + MC_ERRLINE]
        call    af_buf_free
        lea     rdi, [rsp + MC_ERRLOG]
        call    af_buf_free
        AF_TEST_END

        AF_TEST "mcp/restart/sliding_window_latches_at_the_rolling_boundary", 2560
%define RB_CHILD 0
%define RB_CFG   ((MC_SIZE + 15) & ~15)
AF_STATIC_ASSERT RB_CFG >= MC_SIZE, "restart config overlaps af_mcp_child"
AF_STATIC_ASSERT (RB_CFG + MCP_SIZE) <= 2560, "restart fixture exceeds its stack frame"
        lea     rdi, [rsp]
        mov     rsi, RB_CFG + MCP_SIZE
        call    af_mem_zero
        lea     rax, [rsp + RB_CFG]
        mov     [rsp + RB_CHILD + MC_CFG], rax
        mov     qword [rsp + RB_CFG + MCP_RESTART_MODE], AF_RESTART_ON_FAILURE
        mov     qword [rsp + RB_CFG + MCP_MAX_RESTARTS], 2
        mov     qword [rsp + RB_CFG + MCP_WINDOW_MS], 10000
        mov     qword [rsp + RB_CFG + MCP_BACKOFF_MS], 10
        mov     qword [rsp + RB_CFG + MCP_MAX_BACKOFF_MS], 40

        ; max=2, window=10s. A tumbling implementation would incorrectly
        ; forget the t=9 event when the original t=0 window expires.
        xor     edi, edi
        call    af_clock_set_override_ns
        lea     rdi, [rsp + RB_CHILD]
        call    af_mcp_schedule_restart
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_RESTARTING, "t=0 restart is scheduled"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTARTS], 1, "t=0 leaves one live timestamp"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTART_HISTORY], 0, "timestamp zero is retained using the separate count"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_WINDOW_START], 0, "the oldest timestamp may legitimately be zero"

        mov     rdi, 9000000000
        call    af_clock_set_override_ns
        lea     rdi, [rsp + RB_CHILD]
        call    af_mcp_schedule_restart
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTARTS], 2, "t=9 retains both timestamps"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTART_HISTORY + 8], 9000000000, "t=9 is appended in order"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_BACKOFF_MS], 20, "backoff doubles while the window remains active"

        mov     rdi, 10100000000
        call    af_clock_set_override_ns
        lea     rdi, [rsp + RB_CHILD]
        call    af_mcp_schedule_restart
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_RESTARTING, "t=10.1 may restart after t=0 expires"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTARTS], 2, "t=10.1 compacts then appends"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_WINDOW_START], 9000000000, "rolling window starts at the surviving t=9 event"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTART_HISTORY], 9000000000, "t=9 survives compaction"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTART_HISTORY + 8], 10100000000, "t=10.1 follows the survivor"

        mov     rdi, 10200000000
        call    af_clock_set_override_ns
        lea     rdi, [rsp + RB_CHILD]
        call    af_mcp_schedule_restart
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_CRASH_LOOP, "t=10.2 latches because t=9 and t=10.1 both survive"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTARTS], 2, "latching does not append an unavailable third budget unit"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_WINDOW_START], 9000000000, "latch retains the true rolling-window origin"

        lea     rdi, [rsp + RB_CHILD]
        call    af_mcp_reset
        AF_CHECK_OK rax, "explicit crash-loop reset releases the latch"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTARTS], 0, "reset clears live history count"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_WINDOW_START], 0, "reset clears rolling-window origin"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTART_HISTORY], 0, "reset clears the first timestamp"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTART_HISTORY + 8], 0, "reset clears the second timestamp"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_BACKOFF_MS], 0, "reset returns backoff to base state"

        mov     rdi, -1
        call    af_clock_set_override_ns
        AF_TEST_END

        AF_TEST "mcp/restart/mode_distinguishes_clean_and_failed_exits", 2560
        ; A clean already-collected child under on_failure stops without
        ; spending budget. MC_STARTS keeps the sweep from treating STOPPED as
        ; a never-started child and immediately attempting its first spawn.
        lea     rdi, [rsp]
        mov     rsi, RB_CFG + MCP_SIZE
        call    af_mem_zero
        lea     rax, [rsp + RB_CFG]
        mov     [rsp + RB_CHILD + MC_CFG], rax
        mov     qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_READY
        mov     qword [rsp + RB_CHILD + MC_STARTS], 1
        mov     qword [rsp + RB_CHILD + MC_STDIN_FD], -1
        mov     qword [rsp + RB_CHILD + MC_STDOUT_FD], -1
        mov     qword [rsp + RB_CHILD + MC_STDERR_FD], -1
        mov     qword [rsp + RB_CFG + MCP_RESTART_MODE], AF_RESTART_ON_FAILURE
        call    af_sys_getpid
        mov     [rsp + RB_CHILD + MC_PID], rax
        lea     rdi, [rsp + RB_CHILD]
        xor     esi, esi
        mov     rdx, 1000000
        call    af_mcp_sweep_child
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_STOPPED, "on_failure leaves a clean exit stopped"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTARTS], 0, "a clean exit spends no on_failure budget"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_NEXT_START], 0, "a clean exit has no restart deadline"

        ; `always` schedules that same raw exit(0).
        lea     rdi, [rsp]
        mov     rsi, RB_CFG + MCP_SIZE
        call    af_mem_zero
        lea     rax, [rsp + RB_CFG]
        mov     [rsp + RB_CHILD + MC_CFG], rax
        mov     qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_READY
        mov     qword [rsp + RB_CHILD + MC_STARTS], 1
        mov     qword [rsp + RB_CHILD + MC_STDIN_FD], -1
        mov     qword [rsp + RB_CHILD + MC_STDOUT_FD], -1
        mov     qword [rsp + RB_CHILD + MC_STDERR_FD], -1
        mov     qword [rsp + RB_CFG + MCP_RESTART_MODE], AF_RESTART_ALWAYS
        mov     qword [rsp + RB_CFG + MCP_MAX_RESTARTS], 2
        mov     qword [rsp + RB_CFG + MCP_WINDOW_MS], 1000
        mov     qword [rsp + RB_CFG + MCP_BACKOFF_MS], 10
        mov     qword [rsp + RB_CFG + MCP_MAX_BACKOFF_MS], 40
        mov     rdi, 1000000
        call    af_clock_set_override_ns
        call    af_sys_getpid
        mov     [rsp + RB_CHILD + MC_PID], rax
        lea     rdi, [rsp + RB_CHILD]
        xor     esi, esi
        mov     rdx, 1000000
        call    af_mcp_sweep_child
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_RESTARTING, "always schedules a clean exit"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTARTS], 1, "always spends one restart budget unit"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_NEXT_START], 11000000, "always applies the configured backoff"

        ; A nonzero exit remains a failure under on_failure.
        lea     rdi, [rsp]
        mov     rsi, RB_CFG + MCP_SIZE
        call    af_mem_zero
        lea     rax, [rsp + RB_CFG]
        mov     [rsp + RB_CHILD + MC_CFG], rax
        mov     qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_READY
        mov     qword [rsp + RB_CHILD + MC_STARTS], 1
        mov     qword [rsp + RB_CHILD + MC_STDIN_FD], -1
        mov     qword [rsp + RB_CHILD + MC_STDOUT_FD], -1
        mov     qword [rsp + RB_CHILD + MC_STDERR_FD], -1
        mov     qword [rsp + RB_CHILD + MC_LAST_EXIT], 0x100
        mov     qword [rsp + RB_CFG + MCP_RESTART_MODE], AF_RESTART_ON_FAILURE
        mov     qword [rsp + RB_CFG + MCP_MAX_RESTARTS], 2
        mov     qword [rsp + RB_CFG + MCP_WINDOW_MS], 1000
        mov     qword [rsp + RB_CFG + MCP_BACKOFF_MS], 10
        mov     qword [rsp + RB_CFG + MCP_MAX_BACKOFF_MS], 40
        call    af_sys_getpid
        mov     [rsp + RB_CHILD + MC_PID], rax
        lea     rdi, [rsp + RB_CHILD]
        xor     esi, esi
        mov     rdx, 1000000
        call    af_mcp_sweep_child
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_RESTARTING, "on_failure schedules a nonzero exit"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTARTS], 1, "a failed exit spends on_failure budget"

        ; A protocol failure uses the same bounded stop path as stdout EOF,
        ; but a cooperative exit(0) must not erase the original failure.
        lea     rdi, [rsp]
        mov     rsi, RB_CFG + MCP_SIZE
        call    af_mem_zero
        lea     rax, [rsp + RB_CFG]
        mov     [rsp + RB_CHILD + MC_CFG], rax
        mov     qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_FAILED
        mov     qword [rsp + RB_CHILD + MC_STARTS], 1
        mov     qword [rsp + RB_CHILD + MC_STDIN_FD], -1
        mov     qword [rsp + RB_CHILD + MC_STDOUT_FD], -1
        mov     qword [rsp + RB_CHILD + MC_STDERR_FD], -1
        or      qword [rsp + RB_CHILD + MC_FLAGS], (AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP | AF_MC_F_EOF | AF_MC_F_PROCESS_FAILURE)
        mov     qword [rsp + RB_CFG + MCP_RESTART_MODE], AF_RESTART_ON_FAILURE
        mov     qword [rsp + RB_CFG + MCP_MAX_RESTARTS], 2
        mov     qword [rsp + RB_CFG + MCP_WINDOW_MS], 1000
        mov     qword [rsp + RB_CFG + MCP_BACKOFF_MS], 10
        mov     qword [rsp + RB_CFG + MCP_MAX_BACKOFF_MS], 40
        call    af_sys_getpid
        mov     [rsp + RB_CHILD + MC_PID], rax
        lea     rdi, [rsp + RB_CHILD]
        xor     esi, esi
        mov     rdx, 1000000
        call    af_mcp_sweep_child
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_RESTARTING, "later EOF cannot erase protocol failure when child exits zero"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTARTS], 1, "protocol failure spends on_failure budget"

        ; Only a stop path explicitly caused by protocol-pipe EOF may treat
        ; that same raw status as a clean non-restarting exit.
        lea     rdi, [rsp]
        mov     rsi, RB_CFG + MCP_SIZE
        call    af_mem_zero
        lea     rax, [rsp + RB_CFG]
        mov     [rsp + RB_CHILD + MC_CFG], rax
        mov     qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_FAILED
        mov     qword [rsp + RB_CHILD + MC_STARTS], 1
        mov     qword [rsp + RB_CHILD + MC_STDIN_FD], -1
        mov     qword [rsp + RB_CHILD + MC_STDOUT_FD], -1
        mov     qword [rsp + RB_CHILD + MC_STDERR_FD], -1
        or      qword [rsp + RB_CHILD + MC_FLAGS], (AF_MC_F_STOPPING | AF_MC_F_RESTART_AFTER_STOP | AF_MC_F_EOF)
        mov     qword [rsp + RB_CFG + MCP_RESTART_MODE], AF_RESTART_ON_FAILURE
        call    af_sys_getpid
        mov     [rsp + RB_CHILD + MC_PID], rax
        lea     rdi, [rsp + RB_CHILD]
        xor     esi, esi
        mov     rdx, 1000000
        call    af_mcp_sweep_child
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_STATE], AF_MCP_S_STOPPED, "clean EOF exit stays stopped under on_failure"
        AF_CHECK_EQ qword [rsp + RB_CHILD + MC_RESTARTS], 0, "clean EOF exit spends no on_failure budget"

        mov     rdi, -1
        call    af_clock_set_override_ns
        AF_TEST_END
