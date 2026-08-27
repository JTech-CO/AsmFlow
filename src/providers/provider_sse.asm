; AsmFlow — Server-Sent Events, framed but not interpreted.
;
; A streaming response is a byte stream that libcurl hands over in whatever
; sizes the network produced. HARNESS.md M6 is explicit that one callback must
; not be assumed to carry one event: it may carry a fraction of one, several, or
; a boundary in the middle of a multi-byte character.
;
; This file finds event boundaries. It does not parse events. That distinction
; is the whole design:
;
;   - Nothing here decodes UTF-8, so a character split across two callbacks
;     cannot be corrupted by this code. There is no decode to get wrong.
;   - Nothing here reads `data:`, `event:`, or `id:`. AsmFlow is a gateway, and
;     a gateway that understood the payload would be a gateway that could
;     change it.
;   - The bytes forwarded to the client are the bytes the provider sent, in
;     order, byte for byte, including the terminator.
;
; The one thing a boundary IS needed for is `limits.sse_event_max_bytes`. That
; limit only means something if an event is a unit, so an event is accumulated
; before it is forwarded and the ceiling applies to the accumulation. The cost
; is the latency of one event, which for a token stream is the latency of one
; token; the alternative — forwarding as bytes arrive — would make the
; configured limit unenforceable, because half an oversized event would already
; be on the wire when the limit was reached.
;
; An event ends at an empty line, and SSE allows three line terminators: CRLF,
; LF, and a bare CR. A buffer ending in a bare CR is therefore undecidable —
; the next byte may be the LF that completes a CRLF — and the scanner says "not
; yet" rather than guessing. Guessing would split one event into two.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "http.inc"
%include "provider.inc"

        extern af_buf_data
        extern af_buf_len
        extern af_buf_clear
        extern af_buf_append
        extern af_buf_consume

        extern af_prov_emit_chunk

        section .text

; ---------------------------------------------------------------------------
; af_prov_sse_scan(const char *p, u64 n) -> i64
;
; The length of the first complete event in `p`, including its terminating
; empty line, or 0 when no event has finished yet.
;
; Exported rather than kept local because it is the piece the fragment corpus
; actually exercises: a test can feed it a byte at a time and compare against
; the same bytes delivered whole, with no socket, no provider, and no daemon.
; ---------------------------------------------------------------------------
        global af_prov_sse_scan
af_prov_sse_scan:
        AF_ENTER 0
        test    rdi, rdi
        jz      .none
        test    rsi, rsi
        jz      .none
        mov     rbx, rdi                        ; p
        mov     r12, rsi                        ; n
        xor     r13, r13                        ; i, the cursor
        xor     r14, r14                        ; line_start

.scan:
        cmp     r13, r12
        jae     .none
        movzx   eax, byte [rbx + r13]
        cmp     al, 13                          ; CR
        je      .carriage
        cmp     al, 10                          ; LF
        je      .line_feed
        inc     r13
        jmp     .scan

.carriage:
        ; A CR at the very end of what has arrived cannot be classified: the
        ; next byte decides whether the terminator is one byte or two.
        lea     rax, [r13 + 1]
        cmp     rax, r12
        jae     .none
        mov     r15, 1
        cmp     byte [rbx + r13 + 1], 10
        jne     .have_eol
        mov     r15, 2
        jmp     .have_eol
.line_feed:
        mov     r15, 1

.have_eol:
        ; The line just closed runs [line_start, i). An empty one ends the
        ; event, and the event includes the empty line's terminator.
        cmp     r13, r14
        jne     .next_line
        lea     rax, [r13 + r15]
        AF_LEAVE
.next_line:
        add     r13, r15
        mov     r14, r13
        jmp     .scan

.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_sse_feed(af_prov_exchange *x, const char *at, u64 len) -> af_status
;
; Accumulates upstream bytes and forwards every event that completes. A single
; call may complete none, one, or many.
; ---------------------------------------------------------------------------
        global af_prov_sse_feed
af_prov_sse_feed:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        test    r13, r13
        jz      .ok

        lea     rdi, [rbx + PX_CARRY]
        mov     rsi, r12
        mov     rdx, r13
        call    af_buf_append
        test    rax, rax
        js      .done

.drain:
        lea     rdi, [rbx + PX_CARRY]
        call    af_buf_data
        mov     r14, rax
        test    r14, r14
        jz      .ok
        lea     rdi, [rbx + PX_CARRY]
        call    af_buf_len
        mov     r15, rax
        test    r15, r15
        jz      .ok

        mov     rdi, r14
        mov     rsi, r15
        call    af_prov_sse_scan
        test    rax, rax
        jz      .incomplete
        mov     [rsp], rax

        ; The ceiling is checked against the completed event rather than
        ; against what has accumulated, so an event that is exactly at the
        ; limit is delivered and one byte more is refused.
        mov     rcx, [rbx + PX_SSE_LIMIT]
        test    rcx, rcx
        jz      .no_limit
        cmp     rax, rcx
        ja      .too_large
.no_limit:

        mov     rdi, rbx
        mov     rsi, r14
        mov     rdx, [rsp]
        call    af_prov_emit_chunk
        test    rax, rax
        js      .done

        inc     qword [rbx + PX_EVENTS]
        lea     rdi, [rbx + PX_CARRY]
        mov     rsi, [rsp]
        call    af_buf_consume
        test    rax, rax
        js      .done
        jmp     .drain

.incomplete:
        ; Nothing complete yet. What has accumulated is still bounded, or a
        ; provider that never sends an empty line would grow this buffer for
        ; as long as it kept talking.
        mov     rcx, [rbx + PX_SSE_LIMIT]
        test    rcx, rcx
        jz      .ok
        cmp     r15, rcx
        ja      .too_large
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.too_large:
        or      qword [rbx + PX_FLAGS], AF_PX_F_OVERFLOW
        AF_LEAVE_ERR AF_E_LIMIT
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_sse_finish(af_prov_exchange *x) -> af_status
;
; End of stream. Anything still in the carry buffer is an event the provider
; did not terminate. It is forwarded rather than dropped: the transfer either
; ended cleanly, in which case those bytes are the provider's last word and
; discarding them would lose data the contract promises to pass through, or it
; ended in a failure, in which case the failure is reported separately and the
; client is better off seeing what did arrive.
;
; Unless the ceiling is why the stream ended. Then the carry holds precisely
; the bytes `limits.sse_event_max_bytes` refused, and flushing them here would
; undo the refusal at the last possible moment — the limit would appear to
; work, right up until the transfer finished and delivered everything anyway.
; ---------------------------------------------------------------------------
        global af_prov_sse_finish
af_prov_sse_finish:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        test    qword [rbx + PX_FLAGS], AF_PX_F_OVERFLOW
        jnz     .discard

        lea     rdi, [rbx + PX_CARRY]
        call    af_buf_len
        test    rax, rax
        jz      .ok
        mov     [rsp], rax
        lea     rdi, [rbx + PX_CARRY]
        call    af_buf_data
        test    rax, rax
        jz      .ok
        mov     rdi, rbx
        mov     rsi, rax
        mov     rdx, [rsp]
        call    af_prov_emit_chunk
        test    rax, rax
        js      .done
        inc     qword [rbx + PX_EVENTS]
        lea     rdi, [rbx + PX_CARRY]
        call    af_buf_clear
.ok:
        xor     eax, eax
.done:
        AF_LEAVE
.discard:
        lea     rdi, [rbx + PX_CARRY]
        call    af_buf_clear
        xor     eax, eax
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_sse_events(const af_prov_exchange *x) -> u64
; ---------------------------------------------------------------------------
        global af_prov_sse_events
af_prov_sse_events:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + PX_EVENTS]
        ret
.zero:
        xor     eax, eax
        ret
