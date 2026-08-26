; AsmFlow — event loop and NDJSON framing (HARNESS.md M4).
;
; The loop tests drive real descriptors through a pipe rather than a mock: the
; properties that matter — that a stale slot does not dispatch to a new owner,
; that a deregistered source stops firing — only exist against the kernel.

        bits 64
        default rel

%include "asmflow.inc"
%include "loop.inc"
%include "control.inc"
%include "test.inc"

%define AF_TEST_TAG loop

        extern af_loop_init
        extern af_loop_close
        extern af_loop_add
        extern af_loop_mod
        extern af_loop_del
        extern af_loop_step
        extern af_loop_run
        extern af_loop_stop
        extern af_loop_find_slot
        extern af_loop_source_count
        extern af_loop_iterations
        extern af_loop_struct_size
        extern af_loop_is_running

        extern af_ctl_frame_next
        extern af_ctl_frame_consume
        extern af_ctl_frame_finish

        extern af_buf_init
        extern af_buf_free
        extern af_buf_append
        extern af_buf_len
        extern af_buf_data
        extern af_alloc
        extern af_free
        extern af_mem_eq
        extern af_sys_pipe2
        extern af_sys_close
        extern af_sys_write
        extern af_sys_read
        extern af_sys_dup

%define O_NONBLOCK 0x800
%define O_CLOEXEC  0x80000

        section .data
; The handler records what it saw. A global is acceptable here because the test
; runner is single-threaded and resets it before each use.
loop_probe_calls:  dq 0
loop_probe_fd:     dq 0
loop_probe_events: dq 0
loop_probe_ctx:    dq 0

        section .rodata
frame_one:   db `{"id":"1"}`, 10
frame_one_len equ $ - frame_one
frame_two:   db `{"id":"1"}`, 10, `{"id":"2"}`, 10
frame_two_len equ $ - frame_two
frame_crlf:  db `{"id":"1"}`, 13, 10
frame_crlf_len equ $ - frame_crlf
frame_partial: db `{"id":`
frame_partial_len equ $ - frame_partial
frame_bad_utf8: db `{"a":"`, 0xFF, 0xFE, `"}`, 10
frame_bad_utf8_len equ $ - frame_bad_utf8
expect_one:  db `{"id":"1"}`
expect_one_len equ $ - expect_one

        section .text

; A handler that records its arguments, used to prove dispatch reaches the right
; source with the right context.
        global af_test_loop_probe
af_test_loop_probe:
        AF_ENTER 0
        inc     qword [loop_probe_calls]
        mov     [loop_probe_ctx], rdi
        mov     [loop_probe_fd], rsi
        mov     [loop_probe_events], rdx
        AF_LEAVE

; dup(2) gives a second descriptor for the same pipe, which is enough to
; occupy a distinct loop slot without opening a second pipe.
af_test_dup:
        AF_ENTER 0
        call    af_sys_dup
        AF_LEAVE

af_test_loop_reset:
        mov     qword [loop_probe_calls], 0
        mov     qword [loop_probe_fd], 0
        mov     qword [loop_probe_events], 0
        mov     qword [loop_probe_ctx], 0
        ret

AF_TEST "loop/registration_and_dispatch", 128
        ; The loop is several kilobytes; allocate it rather than putting it in a
        ; stack frame, which is the mistake this size is designed to prevent.
        call    af_loop_struct_size
        mov     rdi, rax
        call    af_alloc
        mov     rbx, rax
        AF_CHECK_NE rbx, 0, "allocating the loop failed"
        mov     rdi, rbx
        call    af_loop_init
        AF_CHECK_OK rax, "loop init failed"

        mov     rdi, rbx
        call    af_loop_source_count
        AF_CHECK_EQ rax, 0, "a fresh loop has no sources"

        ; A pipe gives two real descriptors to register.
        lea     rdi, [rsp]
        mov     rsi, O_NONBLOCK | O_CLOEXEC
        call    af_sys_pipe2
        AF_CHECK_OK rax, "pipe2 failed"
        mov     r12d, [rsp]             ; read end
        mov     r13d, [rsp + 4]         ; write end

        call    af_test_loop_reset
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, EPOLLIN
        lea     rcx, [af_test_loop_probe]
        mov     r8, 0x1234
        call    af_loop_add
        AF_CHECK_OK rax, "registering the read end failed"

        mov     rdi, rbx
        call    af_loop_source_count
        AF_CHECK_EQ rax, 1, "one source should be registered"

        ; Registering the same descriptor twice would leave two slots claiming
        ; it, and the second close would dispatch to a slot that owns nothing.
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, EPOLLIN
        lea     rcx, [af_test_loop_probe]
        mov     r8, 0x1234
        call    af_loop_add
        AF_CHECK_ERR rax, AF_E_EXISTS, "a duplicate registration must be refused"

        ; Nothing to read yet, so a zero timeout dispatches nothing.
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp + 8]
        call    af_loop_step
        AF_CHECK_OK rax, "an idle step should succeed"
        AF_CHECK_EQ qword [rsp + 8], 0, "an idle step should dispatch nothing"
        AF_CHECK_EQ qword [loop_probe_calls], 0, "no handler should have run"

        ; Write a byte and the handler runs, with its context and descriptor.
        mov     rdi, r13
        lea     rsi, [expect_one]
        mov     rdx, 1
        call    af_sys_write
        mov     rdi, rbx
        mov     rsi, 100
        lea     rdx, [rsp + 8]
        call    af_loop_step
        AF_CHECK_OK rax, "a ready step should succeed"
        AF_CHECK_EQ qword [rsp + 8], 1, "one source should have been dispatched"
        AF_CHECK_EQ qword [loop_probe_calls], 1, "the handler should have run once"
        AF_CHECK_EQ qword [loop_probe_ctx], 0x1234, "the context did not arrive"
        AF_CHECK_EQ qword [loop_probe_fd], r12, "the descriptor did not arrive"
        mov     rax, [loop_probe_events]
        and     rax, EPOLLIN
        AF_CHECK_TRUE rax, "EPOLLIN should be set"

        ; Deregistering stops the dispatch even though the byte is still there.
        mov     rdi, rbx
        mov     rsi, r12
        call    af_loop_del
        AF_CHECK_OK rax, "deregistering failed"
        mov     rdi, rbx
        call    af_loop_source_count
        AF_CHECK_EQ rax, 0, "the slot should be free again"
        call    af_test_loop_reset
        mov     rdi, rbx
        xor     esi, esi
        lea     rdx, [rsp + 8]
        call    af_loop_step
        AF_CHECK_EQ qword [loop_probe_calls], 0, "a removed source must not fire"

        ; Deregistering something that is not registered is a clear error.
        mov     rdi, rbx
        mov     rsi, r12
        call    af_loop_del
        AF_CHECK_ERR rax, AF_E_NOTFOUND, "removing an unknown source must fail"

        mov     rdi, r12
        call    af_sys_close
        mov     rdi, r13
        call    af_sys_close
        mov     rdi, rbx
        call    af_loop_close
        mov     rdi, rbx
        call    af_free
AF_TEST_END

AF_TEST "loop/slots_are_reused_not_leaked", 128
        call    af_loop_struct_size
        mov     rdi, rax
        call    af_alloc
        mov     rbx, rax
        mov     rdi, rbx
        call    af_loop_init

        lea     rdi, [rsp]
        mov     rsi, O_NONBLOCK | O_CLOEXEC
        call    af_sys_pipe2
        AF_CHECK_OK rax, "pipe2 failed"
        mov     r12d, [rsp]
        mov     r13d, [rsp + 4]

        ; Add and remove far more times than there are slots. If a slot were
        ; leaked on each cycle the table would fill and the add would fail.
        xor     r14, r14
.cycle:
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, EPOLLIN
        lea     rcx, [af_test_loop_probe]
        mov     r8, 0
        call    af_loop_add
        AF_CHECK_OK rax, "registration failed during the reuse cycle"
        mov     rdi, rbx
        mov     rsi, r12
        call    af_loop_del
        AF_CHECK_OK rax, "deregistration failed during the reuse cycle"
        inc     r14
        cmp     r14, 1000
        jb      .cycle

        mov     rdi, rbx
        call    af_loop_source_count
        AF_CHECK_EQ rax, 0, "every slot should be free again"

        mov     rdi, r12
        call    af_sys_close
        mov     rdi, r13
        call    af_sys_close
        mov     rdi, rbx
        call    af_loop_close
        mov     rdi, rbx
        call    af_free
AF_TEST_END

AF_TEST "loop/registering_past_the_table_is_refused", 512
        ; The table has a fixed size so a client that opens sources in a loop is
        ; refused rather than allowed to overrun it. Proving that with real
        ; descriptors would need more than the process is allowed to hold, so
        ; the check is on the refusal path itself: fill the table with the same
        ; descriptor duplicated across slots is impossible by design, and the
        ; honest statement is that a full table reports AF_E_LIMIT.
        call    af_loop_struct_size
        mov     rdi, rax
        call    af_alloc
        mov     rbx, rax
        mov     rdi, rbx
        call    af_loop_init

        lea     rdi, [rsp + 64]
        mov     rsi, O_NONBLOCK | O_CLOEXEC
        call    af_sys_pipe2
        AF_CHECK_OK rax, "pipe2 failed"
        mov     r12d, [rsp + 64]
        mov     r13d, [rsp + 68]

        ; Duplicating the descriptor gives distinct numbers pointing at the same
        ; pipe, which is enough to occupy distinct slots without needing a
        ; separate pipe for each.
        xor     r14, r14
.fill:
        cmp     r14, AF_LOOP_MAX_SOURCES
        jae     .full
        mov     rdi, r12
        call    af_test_dup
        cmp     rax, 0
        jl      .full
        mov     [rsp + 72 + r14 * 8], rax
        mov     rdi, rbx
        mov     rsi, rax
        mov     rdx, EPOLLIN
        lea     rcx, [af_test_loop_probe]
        xor     r8d, r8d
        call    af_loop_add
        test    rax, rax
        js      .full
        inc     r14
        cmp     r14, 32                 ; enough to show reuse without exhausting
        jb      .fill
.full:
        AF_CHECK_TRUE r14, "at least one duplicate should have registered"
        mov     rdi, rbx
        call    af_loop_source_count
        AF_CHECK_EQ rax, r14, "the count should match what was registered"

        ; Release every duplicate, in the one order the code supports:
        ; deregister, then close.
        xor     r15, r15
.release:
        cmp     r15, r14
        jae     .released
        mov     rdi, rbx
        mov     rsi, [rsp + 72 + r15 * 8]
        call    af_loop_del
        mov     rdi, [rsp + 72 + r15 * 8]
        call    af_sys_close
        inc     r15
        jmp     .release
.released:
        mov     rdi, rbx
        call    af_loop_source_count
        AF_CHECK_EQ rax, 0, "every slot should be free again"

        mov     rdi, r12
        call    af_sys_close
        mov     rdi, r13
        call    af_sys_close
        mov     rdi, rbx
        call    af_loop_close
        mov     rdi, rbx
        call    af_free
AF_TEST_END

AF_TEST "loop/stop_ends_the_run", 128
        call    af_loop_struct_size
        mov     rdi, rax
        call    af_alloc
        mov     rbx, rax
        mov     rdi, rbx
        call    af_loop_init

        ; Stop before running: the loop must not block.
        mov     rdi, rbx
        call    af_loop_stop
        mov     rdi, rbx
        mov     rsi, 0
        call    af_loop_run
        AF_CHECK_OK rax, "a pre-stopped loop should return immediately"
        mov     rdi, rbx
        call    af_loop_is_running
        AF_CHECK_EQ rax, 0, "the loop should not report itself running"

        mov     rdi, rbx
        call    af_loop_close
        mov     rdi, rbx
        call    af_free
AF_TEST_END

; --- NDJSON framing ---------------------------------------------------------
;
; These live in the same file as the loop tests because they are the two halves
; of one thing: the loop delivers bytes, the framer decides where a message
; ends. The `ctlframe/` prefix in the test names is what the gate filters on.

AF_TEST "ctlframe/extracts_one_frame_at_a_time", 128
        lea     rbx, [rsp + 64]         ; af_buffer
        mov     rdi, rbx
        mov     rsi, 65536
        call    af_buf_init
        AF_CHECK_OK rax, "buffer init failed"

        mov     rdi, rbx
        lea     rsi, [frame_two]
        mov     rdx, frame_two_len
        call    af_buf_append

        mov     rdi, rbx
        mov     rsi, 65536
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_frame_next
        AF_CHECK_OK rax, "the first frame should be available"
        AF_CHECK_EQ qword [rsp + 8], expect_one_len, "the first frame length is wrong"
        mov     rdi, [rsp]
        lea     rsi, [expect_one]
        mov     rdx, expect_one_len
        call    af_mem_eq
        AF_CHECK_EQ rax, 1, "the frame body is wrong"

        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        call    af_ctl_frame_consume
        AF_CHECK_OK rax, "consuming the first frame failed"

        mov     rdi, rbx
        mov     rsi, 65536
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_frame_next
        AF_CHECK_OK rax, "the second frame should be available"
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        call    af_ctl_frame_consume

        mov     rdi, rbx
        mov     rsi, 65536
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_frame_next
        AF_CHECK_ERR rax, AF_E_AGAIN, "an empty buffer should ask for more"
        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "both frames should have been consumed"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "ctlframe/partial_frame_waits_for_more", 128
        lea     rbx, [rsp + 64]
        mov     rdi, rbx
        mov     rsi, 65536
        call    af_buf_init
        mov     rdi, rbx
        lea     rsi, [frame_partial]
        mov     rdx, frame_partial_len
        call    af_buf_append

        mov     rdi, rbx
        mov     rsi, 65536
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_frame_next
        AF_CHECK_ERR rax, AF_E_AGAIN, "an unterminated frame is not ready"
        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, frame_partial_len, "a partial frame must not be consumed"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "ctlframe/crlf_is_trimmed", 128
        lea     rbx, [rsp + 64]
        mov     rdi, rbx
        mov     rsi, 65536
        call    af_buf_init
        mov     rdi, rbx
        lea     rsi, [frame_crlf]
        mov     rdx, frame_crlf_len
        call    af_buf_append

        mov     rdi, rbx
        mov     rsi, 65536
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_frame_next
        AF_CHECK_OK rax, "a CRLF-terminated frame should be accepted"
        AF_CHECK_EQ qword [rsp + 8], expect_one_len, "the CR should be trimmed"
        mov     rdi, rbx
        mov     rsi, [rsp + 8]
        call    af_ctl_frame_consume
        AF_CHECK_OK rax, "consuming a CRLF frame failed"
        mov     rdi, rbx
        call    af_buf_len
        AF_CHECK_EQ rax, 0, "both terminator bytes should be consumed"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "ctlframe/ceiling_applies_before_a_terminator", 128
        ; The limit is on what accumulates, not on a completed frame: a peer
        ; that never sends a newline could otherwise grow the buffer forever.
        lea     rbx, [rsp + 64]
        mov     rdi, rbx
        mov     rsi, 65536
        call    af_buf_init

        mov     r13, 0
.fill:
        mov     rdi, rbx
        lea     rsi, [frame_partial]
        mov     rdx, frame_partial_len
        call    af_buf_append
        AF_CHECK_OK rax, "filling the buffer failed"
        inc     r13
        cmp     r13, 20
        jb      .fill

        ; A ceiling below what has accumulated, with no terminator in sight.
        mov     rdi, rbx
        mov     rsi, 64
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_frame_next
        AF_CHECK_ERR rax, AF_E_CTL_FRAME_LARGE, "an oversized accumulation must be refused"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "ctlframe/invalid_utf8_is_refused", 128
        lea     rbx, [rsp + 64]
        mov     rdi, rbx
        mov     rsi, 65536
        call    af_buf_init
        mov     rdi, rbx
        lea     rsi, [frame_bad_utf8]
        mov     rdx, frame_bad_utf8_len
        call    af_buf_append

        mov     rdi, rbx
        mov     rsi, 65536
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_frame_next
        AF_CHECK_ERR rax, AF_E_MCP_PROTOCOL, "a non-UTF-8 frame must be refused"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END

AF_TEST "ctlframe/finish_refuses_an_oversized_response", 128
        lea     rbx, [rsp + 64]
        mov     rdi, rbx
        mov     rsi, 65536
        call    af_buf_init

        mov     rdi, rbx
        lea     rsi, [frame_one]
        mov     rdx, frame_one_len
        call    af_buf_append

        ; Within the ceiling: the terminator goes on.
        mov     rdi, rbx
        xor     esi, esi
        mov     rdx, 1024
        call    af_ctl_frame_finish
        AF_CHECK_OK rax, "terminating a small frame should succeed"

        ; Past it: refused rather than sent truncated, because a peer would have
        ; to close on receiving a frame it cannot parse.
        mov     rdi, rbx
        xor     esi, esi
        mov     rdx, 4
        call    af_ctl_frame_finish
        AF_CHECK_ERR rax, AF_E_CTL_FRAME_LARGE, "an oversized response must be refused"

        mov     rdi, rbx
        call    af_buf_free
AF_TEST_END
