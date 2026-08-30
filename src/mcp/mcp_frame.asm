; AsmFlow — the two pipes coming back from a supervised server.
;
; stdout carries the protocol: one JSON object per line, UTF-8, bounded by
; `limits.mcp_frame_max_bytes` (docs/MCP_COMPATIBILITY.md 11). stderr carries
; whatever the server felt like saying.
;
; Both are drained on every loop turn, and that is a correctness requirement
; rather than tidiness. A pipe has a fixed capacity: a server that logs
; enthusiastically fills stderr, blocks writing to it, and therefore stops
; reading its stdin — so a supervisor that read only the protocol pipe would
; deadlock against a server that was working perfectly well (M8 DoD 7). The
; symptom would be a server stuck in `probing` with nothing wrong in any log.
;
; Three rules on what arrives:
;
; A line that is not a JSON-RPC message is protocol contamination. It is
; counted and returned as AF_E_MCP_PROTOCOL so the supervisor stops the child;
; keeping that child READY would hide exactly the failure that corrupts a
; session and would train server authors to keep doing it.
;
; A line past the ceiling cannot be delivered. Newline framing makes its end
; knowable, but strict MCP policy still treats it as protocol failure rather
; than continuing a session after an untrusted peer exceeded its bound.
;
; The captured stderr keeps the newest bytes, not the oldest. A server that is
; failing says the useful thing last.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "fileio.inc"
%include "loop.inc"
%include "config.inc"
%include "mcp.inc"

        extern af_buf_init
        extern af_buf_free
        extern af_buf_clear
        extern af_buf_data
        extern af_buf_len
        extern af_buf_reserve
        extern af_buf_append
        extern af_buf_consume

        extern af_add_size

        extern af_sys_read
        extern af_sys_write
        extern af_sys_close
        extern af_status_from_errno
        extern af_loop_mod

        extern af_mcp_on_message
        extern af_mcp_child_failed

        section .text

; ---------------------------------------------------------------------------
; af_mcp_read_stdout(af_mcp_child *child) -> af_status
;
; AF_E_EOF when the server closed its stdout, which is how a supervisor learns
; the process has finished talking — usually just before it exits.
; ---------------------------------------------------------------------------
        global af_mcp_read_stdout
af_mcp_read_stdout:
        AF_ENTER (AF_MCP_READ_CHUNK + 64)
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, [rbx + MC_STDOUT_FD]
        cmp     rdi, 0
        jl      .invalid
        lea     rsi, [rsp]
        mov     rdx, AF_MCP_READ_CHUNK
        call    af_sys_read
        test    rax, rax
        js      .failed
        test    rax, rax
        jz      .eof
        mov     [rsp + AF_MCP_READ_CHUNK], rax

        lea     rdi, [rbx + MC_INBOX]
        lea     rsi, [rsp]
        mov     rdx, [rsp + AF_MCP_READ_CHUNK]
        call    af_buf_append
        test    rax, rax
        js      .done

        mov     rdi, rbx
        call    af_mcp_frame_lines
.done:
        AF_LEAVE
.eof:
        AF_LEAVE_ERR AF_E_EOF
.failed:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_AGAIN
        je      .again
        AF_LEAVE
.again:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_frame_lines(af_mcp_child *child) -> af_status
;
; Hands every complete line in the inbox to the message layer.
; ---------------------------------------------------------------------------
        global af_mcp_frame_lines
af_mcp_frame_lines:
        AF_ENTER 64
;   [rsp +  0]  data      [rsp + 16]  newline offset
;   [rsp +  8]  length    [rsp + 24]  ceiling
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rax, [rbx + MC_FRAME_MAX]
        mov     [rsp + 24], rax

.next:
        lea     rdi, [rbx + MC_INBOX]
        call    af_buf_len
        mov     [rsp + 8], rax
        test    rax, rax
        jz      .empty
        lea     rdi, [rbx + MC_INBOX]
        call    af_buf_data
        mov     [rsp], rax
        test    rax, rax
        jz      .done

        ; Find the line terminator.
        mov     r12, [rsp]
        mov     r13, [rsp + 8]
        mov     r14, [rbx + MC_SCAN_CURSOR]
        ; Be defensive about a buffer cleared by its owner between calls.  All
        ; normal consume/clear paths below reset the cursor explicitly.
        cmp     r14, r13
        jbe     .scan
        xor     r14, r14
.scan:
        cmp     r14, r13
        jae     .incomplete
        cmp     byte [r12 + r14], 10
        je      .found
        inc     r14
        jmp     .scan

.found:
        mov     [rsp + 16], r14
        mov     qword [rbx + MC_SCAN_CURSOR], 0
        test    qword [rbx + MC_FLAGS], AF_MC_F_DISCARDING
        jz      .deliver
        ; The tail of a line that was already too long. Dropping it up to and
        ; including this newline is what puts the stream back in step.
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_DISCARDING
        jmp     .consume

.deliver:
        ; A trailing CR is tolerated, because a server written on a platform
        ; that ends lines with CRLF is a server with a portability bug rather
        ; than a protocol violation, and the JSON is unaffected either way.
        mov     r15, r14
        test    r15, r15
        jz      .no_cr
        cmp     byte [r12 + r15 - 1], 13
        jne     .no_cr
        dec     r15
.no_cr:
        ; A complete line is subject to the same ceiling as an unterminated
        ; accumulation.  The newline tells us where the next frame begins; it
        ; does not make an oversized frame safe to parse or deliver.
        mov     rax, [rsp + 24]
        test    rax, rax
        jz      .within_ceiling
        cmp     r15, rax
        jbe     .within_ceiling
        inc     qword [rbx + MC_OVERSIZED]
        mov     qword [rsp + 32], AF_E_MCP_PROTOCOL
        jmp     .consume_failed
.within_ceiling:
        ; Empty and CR-only lines are stdout noise, not JSON-RPC.  Deliver a
        ; zero-length view so the message layer counts contamination and the
        ; supervisor terminates the corrupted session.
        inc     qword [rbx + MC_FRAMES_IN]
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r15
        call    af_mcp_on_message
        test    rax, rax
        js      .message_failed

.consume:
        lea     rdi, [rbx + MC_INBOX]
        mov     rsi, [rsp + 16]
        inc     rsi                             ; the newline itself
        call    af_buf_consume
        test    rax, rax
        js      .done
        jmp     .next

.message_failed:
        mov     [rsp + 32], rax
.consume_failed:
        ; Do not retry a rejected frame if cleanup observes the inbox before
        ; the supervisor tears the child down. Consume exactly this line, then
        ; propagate the original protocol status without scanning another.
        lea     rdi, [rbx + MC_INBOX]
        mov     rsi, [rsp + 16]
        inc     rsi
        call    af_buf_consume
        mov     rax, [rsp + 32]
        AF_LEAVE

.incomplete:
        ; No terminator yet. What has accumulated is bounded, or a server that
        ; never sent one could grow this buffer for as long as it kept writing
        ; — which is the failure the ceiling exists to prevent.
        mov     rax, [rsp + 24]
        test    rax, rax
        jz      .incomplete_ok
        cmp     r13, rax
        jbe     .incomplete_ok
        inc     qword [rbx + MC_OVERSIZED]
        lea     rdi, [rbx + MC_INBOX]
        call    af_buf_clear
        mov     qword [rbx + MC_SCAN_CURSOR], 0
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL
.incomplete_ok:
        ; Every byte currently buffered has been checked exactly once.  A
        ; later fragment resumes here and scans only newly appended bytes.
        mov     [rbx + MC_SCAN_CURSOR], r13
        xor     eax, eax
        jmp     .done
.empty:
        mov     qword [rbx + MC_SCAN_CURSOR], 0
        xor     eax, eax
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_read_stderr(af_mcp_child *child) -> af_status
;
; Drains what the server has written and keeps a bounded tail of it.
; ---------------------------------------------------------------------------
        global af_mcp_read_stderr
af_mcp_read_stderr:
        AF_ENTER (AF_MCP_READ_CHUNK + 64)
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, [rbx + MC_STDERR_FD]
        cmp     rdi, 0
        jl      .invalid
        lea     rsi, [rsp]
        mov     rdx, AF_MCP_READ_CHUNK
        call    af_sys_read
        test    rax, rax
        js      .failed
        test    rax, rax
        jz      .eof
        mov     r12, rax
        add     [rbx + MC_STDERR_BYTES], r12

        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, r12
        call    af_mcp_capture_stderr
        AF_LEAVE_OK
.eof:
        AF_LEAVE_ERR AF_E_EOF
.failed:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_AGAIN
        je      .again
        AF_LEAVE
.again:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_capture_stderr(af_mcp_child *child, const char *at, u64 len) -> void
;
; Splits the bytes into lines, truncates any line past
; `limits.stderr_line_max_bytes` with a counter, and keeps the newest of what
; results.
;
; Separate from the read so the line policy can be tested without a pipe: a
; flood is easy to write and awkward to arrange through a socket.
; ---------------------------------------------------------------------------
        global af_mcp_capture_stderr
af_mcp_capture_stderr:
        AF_ENTER 64
;   [rsp +  0]  cursor    [rsp + 16]  ceiling
;   [rsp +  8]  length
        test    rdi, rdi
        jz      .done
        test    rsi, rsi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     [rsp + 8], rdx
        mov     qword [rsp], 0

        mov     r13, [rbx + MC_STDERR_MAX]
        test    r13, r13
        jnz     .have_ceiling
        mov     r13, 65536                      ; the schema's own default
.have_ceiling:
        mov     [rsp + 16], r13

.next:
        mov     rax, [rsp]
        cmp     rax, [rsp + 8]
        jae     .done
        movzx   ecx, byte [r12 + rax]
        inc     qword [rsp]
        cmp     cl, 10
        je      .end_of_line

        ; A line past its ceiling is truncated once and counted once; the rest
        ; of it is dropped rather than growing the buffer.
        test    qword [rbx + MC_FLAGS], AF_MC_F_ERR_TRUNCATED
        jnz     .next
        lea     rdi, [rbx + MC_ERRLINE]
        mov     [rsp + 24], rcx
        call    af_buf_len
        mov     rcx, [rsp + 24]
        cmp     rax, [rsp + 16]
        jb      .append
.truncated:
        inc     qword [rbx + MC_STDERR_TRUNC]
        or      qword [rbx + MC_FLAGS], AF_MC_F_ERR_TRUNCATED
        jmp     .next
.append:
        lea     rdi, [rbx + MC_ERRLINE]
        mov     rsi, rcx
        call    af_mcp_errline_byte
        test    rax, rax
        js      .truncated
        jmp     .next

.end_of_line:
        mov     rdi, rbx
        call    af_mcp_flush_errline
        jmp     .next
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_errline_byte(af_buffer *line, u8 byte) -> af_status
; ---------------------------------------------------------------------------
        global af_mcp_errline_byte
af_mcp_errline_byte:
        AF_ENTER 16
        mov     [rsp], sil
        lea     rsi, [rsp]
        mov     rdx, 1
        call    af_buf_append
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_flush_errline(af_mcp_child *child) -> void
;
; Moves the accumulated line into the kept tail, dropping the oldest bytes when
; that tail is full.
; ---------------------------------------------------------------------------
        global af_mcp_flush_errline
af_mcp_flush_errline:
        AF_ENTER 48
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_ERR_TRUNCATED

        lea     rdi, [rbx + MC_ERRLINE]
        call    af_buf_len
        mov     r12, rax
        test    r12, r12
        jz      .done
        lea     rdi, [rbx + MC_ERRLINE]
        call    af_buf_data
        mov     r13, rax
        test    r13, r13
        jz      .clear

        ; Keep exactly the newest suffix of (old tail || line || newline). A
        ; single configured line may be much larger than the 64 KiB tail, so
        ; trimming only the old tail would make the line append fail and leave
        ; behind nothing but its newline.
        lea     rdi, [rbx + MC_ERRLOG]
        call    af_buf_len
        mov     r14, rax

        cmp     r12, AF_MCP_STDERR_KEEP
        jb      .line_fits
        ; The line itself fills the tail. Drop the old tail and skip the oldest
        ; line bytes, reserving the final byte for the newline.
        mov     r15, AF_MCP_STDERR_KEEP - 1
        mov     rax, r12
        sub     rax, r15
        add     r13, rax
        mov     r12, r15
        mov     rsi, r14
        jmp     .consume_old

.line_fits:
        ; At most KEEP - line - newline bytes of the old tail may remain.
        mov     rax, AF_MCP_STDERR_KEEP - 1
        sub     rax, r12
        cmp     r14, rax
        jbe     .append_line
        mov     rsi, r14
        sub     rsi, rax
.consume_old:
        test    rsi, rsi
        jz      .append_line
        lea     rdi, [rbx + MC_ERRLOG]
        call    af_buf_consume
        test    rax, rax
        js      .clear

.append_line:
        lea     rdi, [rbx + MC_ERRLOG]
        mov     rsi, r13
        mov     rdx, r12
        call    af_buf_append
        test    rax, rax
        js      .clear
        lea     rdi, [rbx + MC_ERRLOG]
        mov     rsi, 10
        call    af_mcp_errlog_newline
        test    rax, rax
        js      .clear
.clear:
        lea     rdi, [rbx + MC_ERRLINE]
        call    af_buf_clear
.done:
        AF_LEAVE

        global af_mcp_errlog_newline
af_mcp_errlog_newline:
        AF_ENTER 16
        mov     [rsp], sil
        lea     rsi, [rsp]
        mov     rdx, 1
        call    af_buf_append
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_send(af_mcp_child *child, const char *line, u64 len) -> af_status
;
; Queues one JSON-RPC message and its terminator, then writes what it can. The
; rest goes out when the loop reports the pipe writable — a server that is slow
; to read must not block the daemon.
; ---------------------------------------------------------------------------
        global af_mcp_send
af_mcp_send:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        test    qword [rbx + MC_FLAGS], AF_MC_F_STDIN_OPEN
        jz      .closed

        ; Reserve for the payload and terminator as one transaction. Appending
        ; the line first would let a limit or allocation failure on the LF
        ; leave an unterminated fragment in the shared outbox.
        mov     rdi, r13
        mov     rsi, 1
        lea     rdx, [rsp]
        call    af_add_size
        test    rax, rax
        js      .done
        lea     rdi, [rbx + MC_OUTBOX]
        mov     rsi, [rsp]
        call    af_buf_reserve
        test    rax, rax
        js      .done

        lea     rdi, [rbx + MC_OUTBOX]
        mov     rsi, r12
        mov     rdx, r13
        call    af_buf_append
        test    rax, rax
        js      .done
        lea     rdi, [rbx + MC_OUTBOX]
        mov     rsi, 10
        call    af_mcp_errlog_newline
        test    rax, rax
        js      .done
        inc     qword [rbx + MC_FRAMES_OUT]

        mov     rdi, rbx
        call    af_mcp_write_stdin
.done:
        AF_LEAVE
.closed:
        AF_LEAVE_ERR AF_E_CLOSED
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_write_stdin(af_mcp_child *child) -> af_status
; ---------------------------------------------------------------------------
        global af_mcp_write_stdin
af_mcp_write_stdin:
        AF_ENTER 48
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        cmp     qword [rbx + MC_STDIN_FD], 0
        jl      .done_ok

.write_loop:
        lea     rdi, [rbx + MC_OUTBOX]
        call    af_buf_len
        mov     [rsp], rax
        mov     rcx, [rbx + MC_OUT_CURSOR]
        cmp     rcx, rax
        jae     .drained

        lea     rdi, [rbx + MC_OUTBOX]
        call    af_buf_data
        test    rax, rax
        jz      .drained
        add     rax, [rbx + MC_OUT_CURSOR]
        mov     [rsp + 8], rax
        mov     rax, [rsp]
        sub     rax, [rbx + MC_OUT_CURSOR]
        mov     [rsp + 16], rax

        mov     rdi, [rbx + MC_STDIN_FD]
        mov     rsi, [rsp + 8]
        mov     rdx, [rsp + 16]
        call    af_sys_write
        test    rax, rax
        js      .write_failed
        add     [rbx + MC_OUT_CURSOR], rax
        test    rax, rax
        jz      .would_block
        jmp     .write_loop

.drained:
        lea     rdi, [rbx + MC_OUTBOX]
        call    af_buf_clear
        mov     qword [rbx + MC_OUT_CURSOR], 0
.done_ok:
        AF_LEAVE_OK

.would_block:
        ; Nothing more fits. The loop will say when the pipe drains; until then
        ; the queue holds what is left.
        AF_LEAVE_OK

.write_failed:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_AGAIN
        je      .would_block
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_pending_out(const af_mcp_child *child) -> u64
; ---------------------------------------------------------------------------
        global af_mcp_pending_out
af_mcp_pending_out:
        AF_ENTER 16
        test    rdi, rdi
        jz      .zero
        mov     rbx, rdi
        lea     rdi, [rbx + MC_OUTBOX]
        call    af_buf_len
        sub     rax, [rbx + MC_OUT_CURSOR]
        jc      .zero
        AF_LEAVE
.zero:
        xor     eax, eax
        AF_LEAVE
