; AsmFlow — NDJSON framing for the control protocol.
;
; One JSON object per line, at most `frame_max` bytes including the newline.
; The framer is incremental: it is fed whatever a read produced and extracts as
; many complete frames as that yielded, because a stream socket splits messages
; wherever it likes.
;
; The ceiling is enforced on the ACCUMULATED buffer, not on a completed frame.
; Waiting for the newline before checking the length would let a peer that never
; sends one grow the buffer without bound — which is the whole point of having a
; ceiling. Once the limit is passed the connection is finished: the framer
; cannot resynchronise, because it has no way to know whether the next newline
; ends the oversized frame or a later one.

        bits 64
        default rel

%include "asmflow.inc"
%include "control.inc"

        extern af_buf_data
        extern af_buf_len
        extern af_buf_consume
        extern af_buf_append
        extern af_buf_append_byte
        extern af_utf8_validate

        section .text

; ---------------------------------------------------------------------------
; af_ctl_frame_next(af_buffer *inbox, u64 frame_max, const char **out_ptr,
;                   u64 *out_len) -> af_status
;
; AF_OK           a complete frame is available; `out_ptr`/`out_len` describe it
;                 WITHOUT the newline, borrowed from the inbox and valid only
;                 until the next consume or append
; AF_E_AGAIN      no complete frame yet; read more
; AF_E_CTL_FRAME_LARGE
;                 the accumulated bytes passed the ceiling; the caller must
;                 report the error and close, not retry
; AF_E_MCP_PROTOCOL
;                 the frame is not valid UTF-8
;
; The caller consumes the frame with af_ctl_frame_consume once it has finished
; with the borrowed span.
; ---------------------------------------------------------------------------
        global af_ctl_frame_next
af_ctl_frame_next:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi                ; inbox
        mov     r12, rsi                ; ceiling
        mov     r13, rdx                ; out_ptr
        mov     r14, rcx                ; out_len

        mov     rdi, rbx
        call    af_buf_data
        mov     [rsp], rax
        mov     rdi, rbx
        call    af_buf_len
        mov     [rsp + 8], rax

        test    rax, rax
        jz      .again

        ; Scan for the terminator.
        mov     rdi, [rsp]
        xor     rcx, rcx
.scan:
        cmp     rcx, [rsp + 8]
        jae     .no_newline
        cmp     byte [rdi + rcx], 10
        je      .found
        inc     rcx
        jmp     .scan

.no_newline:
        ; An incomplete frame that has already passed the ceiling can never
        ; become a legal one, so the connection is finished rather than left to
        ; grow.
        mov     rax, [rsp + 8]
        cmp     rax, r12
        jae     .too_large
        jmp     .again

.found:
        mov     [rsp + 16], rcx         ; frame length without the newline
        ; The newline counts toward the ceiling: the limit is on what the peer
        ; sent, not on what survives parsing.
        lea     rax, [rcx + 1]
        cmp     rax, r12
        ja      .too_large

        ; A CR before the newline is accepted and trimmed. Some clients emit
        ; CRLF; rejecting them would be pedantry, and trimming is unambiguous
        ; because a bare CR cannot appear inside a JSON token.
        mov     rcx, [rsp + 16]
        test    rcx, rcx
        jz      .no_cr
        mov     rdi, [rsp]
        cmp     byte [rdi + rcx - 1], 13
        jne     .no_cr
        dec     qword [rsp + 16]
.no_cr:

        mov     rdi, [rsp]
        mov     rsi, [rsp + 16]
        call    af_utf8_validate
        test    rax, rax
        jz      .not_utf8

        mov     rax, [rsp]
        mov     [r13], rax
        mov     rax, [rsp + 16]
        mov     [r14], rax
        AF_LEAVE_OK

.again:
        AF_LEAVE_ERR AF_E_AGAIN
.too_large:
        AF_LEAVE_ERR AF_E_CTL_FRAME_LARGE
.not_utf8:
        AF_LEAVE_ERR AF_E_MCP_PROTOCOL
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_ctl_frame_consume(af_buffer *inbox, u64 frame_len) -> af_status
;
; Removes the frame the previous af_ctl_frame_next returned, plus its
; terminator. `frame_len` is the length that call reported, so the framer
; re-derives how many bytes the line actually occupied rather than trusting the
; caller to remember whether it was CRLF.
; ---------------------------------------------------------------------------
        global af_ctl_frame_consume
af_ctl_frame_consume:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi

        mov     rdi, rbx
        call    af_buf_data
        mov     r13, rax
        mov     rdi, rbx
        call    af_buf_len
        mov     r14, rax

        ; Walk past the frame body, then past an optional CR, then the newline.
        mov     rcx, r12
        cmp     rcx, r14
        ja      .range
        cmp     rcx, r14
        je      .range                  ; the terminator must still be there
        cmp     byte [r13 + rcx], 13
        jne     .at_newline
        inc     rcx
        cmp     rcx, r14
        jae     .range
.at_newline:
        cmp     byte [r13 + rcx], 10
        jne     .range
        inc     rcx

        mov     rdi, rbx
        mov     rsi, rcx
        call    af_buf_consume
        AF_LEAVE
.range:
        AF_LEAVE_ERR AF_E_RANGE

; ---------------------------------------------------------------------------
; af_ctl_frame_finish(af_buffer *outbox, u64 start_len, u64 frame_max)
;   -> af_status
;
; Terminates a frame that was serialised into `outbox` starting at `start_len`.
; A response that would exceed the ceiling is refused HERE rather than sent,
; because a peer would have to close on receiving it and the operator would see
; a dropped connection instead of an error they can act on.
; ---------------------------------------------------------------------------
        global af_ctl_frame_finish
af_ctl_frame_finish:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, rbx
        call    af_buf_len
        sub     rax, r12                ; bytes written for this frame
        inc     rax                     ; plus the terminator
        cmp     rax, r13
        ja      .too_large
        mov     rdi, rbx
        mov     rsi, 10
        call    af_buf_append_byte
        AF_LEAVE
.too_large:
        AF_LEAVE_ERR AF_E_CTL_FRAME_LARGE
