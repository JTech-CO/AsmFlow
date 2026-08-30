; AsmFlow — policy-neutral MCP HTTP multi reactor.
;
; This module embeds a separate libcurl multi handle in the daemon's one epoll
; loop.  It owns transport handles, registration, timerfd integration, and
; bounded byte storage.  It does not decide MCP era, construct modern or legacy
; messages, interpret JSON-RPC, retry, or select fallback.
;
; libcurl owns every socket it reports.  The socket callback only registers or
; deregisters those descriptors; it never closes them.  A zero-millisecond curl
; timer is represented by a one-nanosecond timerfd arm so socket_action is never
; re-entered from a libcurl callback.  Every socket/timer action drains the DONE
; queue before returning to the event loop.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "loop.inc"
%include "socket.inc"
%include "mcp_http.inc"

AF_STATIC_ASSERT AF_MCP_HTTP_MAX_SERVERS = AF_MAX_MCP_SERVERS, "MCP HTTP table no longer covers every configured server"
AF_STATIC_ASSERT (HX_URL + AF_MCP_HTTP_BUFFER_SIZE) = HX_CONFIG, "HX_URL overlaps retained config"
AF_STATIC_ASSERT (HX_CONFIG + 8) = HX_SIZE, "HX_SIZE does not cover retained config"
AF_STATIC_ASSERT HE_SIZE = (HE_TRANSFERS + AF_MCP_HTTP_MAX_TRANSFERS * HX_SIZE), "HE transfer table size drifted"

        extern af_mem_zero
        extern af_mem_eq_ci

        extern af_buf_init
        extern af_buf_free
        extern af_buf_free_secure
        extern af_buf_clear
        extern af_buf_data
        extern af_buf_len
        extern af_buf_append
        extern af_config_release

        extern af_loop_add
        extern af_loop_mod
        extern af_loop_del
        extern af_loop_find_slot

        extern af_sys_timerfd_create
        extern af_sys_timerfd_settime
        extern af_sys_close
        extern af_sys_read
        extern af_status_from_errno

        extern af_curl_mcp_multi_new
        extern af_curl_mcp_easy_new
        extern af_curl_poll_ordinals
        extern af_curl_multi_ordinals
        extern af_curl_multi_free
        extern af_curl_multi_remove
        extern af_curl_multi_socket_action
        extern af_curl_multi_socket_timeout
        extern af_curl_multi_next_done
        extern af_curl_easy_free
        extern af_curl_response_code
        extern af_curl_slist_free

        ; Policy consumes the completed buffers, clears its child/call pointers,
        ; and calls af_mcp_http_slot_release before returning.
        extern af_mcp_http_complete

        section .rodata

mhttp_status_prefix: db "HTTP/"
%define MHTTP_STATUS_PREFIX_LEN 5
mhttp_h_ctype:       db "Content-Type"
%define MHTTP_H_CTYPE_LEN 12
mhttp_h_protocol:    db "MCP-Protocol-Version"
%define MHTTP_H_PROTOCOL_LEN 20
mhttp_h_session:     db "Mcp-Session-Id"
%define MHTTP_H_SESSION_LEN 14
mhttp_ctype_json:    db "application/json"
%define MHTTP_CTYPE_JSON_LEN 16
mhttp_ctype_sse:     db "text/event-stream"
%define MHTTP_CTYPE_SSE_LEN 17
        align 8
mhttp_poll_expected:
        dq AF_CURL_POLL_NONE
        dq AF_CURL_POLL_IN
        dq AF_CURL_POLL_OUT
        dq AF_CURL_POLL_INOUT
        dq AF_CURL_POLL_REMOVE
        dq AF_CURL_SOCKET_TIMEOUT
        dq AF_CURL_CSELECT_IN
        dq AF_CURL_CSELECT_OUT
        dq AF_CURL_CSELECT_ERR

        section .text

; ---------------------------------------------------------------------------
; af_mcp_http_engine_init(engine, loop, supervisor) -> af_status
;
; ENGINE is caller-supplied storage.  LOOP and SUPERVISOR are BORROWED and must
; outlive it.  curl_global_init is owned by daemon startup and is not called.
; ---------------------------------------------------------------------------
        global af_mcp_http_engine_init
af_mcp_http_engine_init:
        AF_ENTER 48
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     [rsp], rsi
        mov     [rsp + 8], rdx

        mov     rdi, rbx
        mov     rsi, HE_SIZE
        call    af_mem_zero
        mov     qword [rbx + HE_TIMER_FD], -1
        call    af_mcp_http_check_ordinals
        test    rax, rax
        js      .fail
        mov     rax, [rsp]
        mov     [rbx + HE_LOOP], rax
        mov     rax, [rsp + 8]
        mov     [rbx + HE_SUP], rax
        mov     qword [rbx + HE_MAX_ACTIVE], AF_MCP_HTTP_MAX_TRANSFERS
        mov     qword [rbx + HE_HEADER_LIMIT], AF_MCP_HTTP_HEADER_DEFAULT
        mov     qword [rbx + HE_BODY_LIMIT], AF_MCP_HTTP_BODY_DEFAULT
        mov     qword [rbx + HE_EVENT_LIMIT], AF_MCP_HTTP_EVENT_DEFAULT

        mov     rdi, rbx
        call    af_curl_mcp_multi_new
        test    rax, rax
        jz      .curl_failed
        mov     [rbx + HE_MULTI], rax
        mov     qword [rbx + HE_STARTED], 1

        mov     rdi, CLOCK_MONOTONIC
        mov     rsi, TFD_NONBLOCK | TFD_CLOEXEC
        call    af_sys_timerfd_create
        test    rax, rax
        js      .syscall_failed
        mov     [rbx + HE_TIMER_FD], rax

        mov     rdi, [rbx + HE_LOOP]
        mov     rsi, [rbx + HE_TIMER_FD]
        mov     rdx, EPOLLIN
        lea     rcx, [af_mcp_http_on_timer_event]
        mov     r8, rbx
        call    af_loop_add
        test    rax, rax
        js      .fail
        AF_LEAVE_OK

.curl_failed:
        mov     rax, AF_E_UNSUPPORTED
        jmp     .fail
.syscall_failed:
        mov     rdi, rax
        call    af_status_from_errno
.fail:
        mov     [rsp + 16], rax
        mov     rdi, rbx
        call    af_mcp_http_engine_shutdown
        mov     rax, [rsp + 16]
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; The MCP reactor can be initialized in a focused harness without the provider
; engine.  Verify the C-header enumerators it consumes rather than relying on a
; different module to have run its own probe first.
af_mcp_http_check_ordinals:
        AF_ENTER 96
; [rsp + 0] poll ordinals (9 qwords), [rsp + 72] multi ordinals (3 qwords)
        lea     rdi, [rsp]
        call    af_curl_poll_ordinals
        lea     rdi, [rsp + 72]
        call    af_curl_multi_ordinals
        lea     rbx, [rsp]
        lea     r12, [mhttp_poll_expected]
        xor     ecx, ecx
.poll:
        cmp     rcx, 9
        jae     .multi
        mov     rax, [rbx + rcx * 8]
        cmp     rax, [r12 + rcx * 8]
        jne     .mismatch
        inc     rcx
        jmp     .poll
.multi:
        cmp     qword [rsp + 72], AF_CURLM_OK
        jne     .mismatch
        AF_LEAVE_OK
.mismatch:
        AF_LEAVE_ERR AF_E_UNSUPPORTED

; ---------------------------------------------------------------------------
; af_mcp_http_engine_shutdown(engine) -> void
;
; Transfers are cancelled first.  The policy hook normally releases each slot;
; the explicit release after it is a shutdown backstop.  The multi handle is
; destroyed while loop/timer context is still live, then the timer is removed
; and closed.  Process-wide curl cleanup is deliberately absent.
; ---------------------------------------------------------------------------
        global af_mcp_http_engine_shutdown
af_mcp_http_engine_shutdown:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        cmp     qword [rbx + HE_STARTED], 0
        je      .done
        ; Prevent a completion hook reached during cancellation from allocating
        ; a fresh slot behind the shutdown scan.
        mov     qword [rbx + HE_STARTED], 0

        xor     r12, r12
.cancel_loop:
        cmp     r12, AF_MCP_HTTP_MAX_TRANSFERS
        jae     .cancelled
        mov     r13, r12
        imul    r13, r13, HX_SIZE
        add     r13, rbx
        add     r13, HE_TRANSFERS
        cmp     qword [r13 + HX_STATE], AF_MCP_HTTP_X_FREE
        je      .cancel_next
        mov     rdi, r13
        mov     rsi, AF_E_CLOSED
        call    af_mcp_http_transfer_cancel
        cmp     qword [r13 + HX_STATE], AF_MCP_HTTP_X_FREE
        je      .cancel_next
        mov     rdi, r13
        call    af_mcp_http_slot_release
.cancel_next:
        inc     r12
        jmp     .cancel_loop
.cancelled:

        mov     rdi, [rbx + HE_MULTI]
        test    rdi, rdi
        jz      .multi_done
        call    af_curl_multi_free
        mov     qword [rbx + HE_MULTI], 0
.multi_done:

        cmp     qword [rbx + HE_TIMER_FD], 0
        jl      .timer_done
        mov     rdi, [rbx + HE_LOOP]
        test    rdi, rdi
        jz      .close_timer
        mov     rsi, [rbx + HE_TIMER_FD]
        call    af_loop_del
.close_timer:
        mov     rdi, [rbx + HE_TIMER_FD]
        call    af_sys_close
        mov     qword [rbx + HE_TIMER_FD], -1
.timer_done:
        mov     qword [rbx + HE_RUNNING], 0
        mov     qword [rbx + HE_ACTIVE], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_http_on_socket(user, fd, CURL_POLL_*) -> i64
; ---------------------------------------------------------------------------
        global af_mcp_http_on_socket
af_mcp_http_on_socket:
        AF_ENTER 32
        test    rdi, rdi
        jz      .bad
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        cmp     r13, AF_CURL_POLL_REMOVE
        je      .remove

        xor     r14, r14
        test    r13, AF_CURL_POLL_IN
        jz      .no_in
        or      r14, EPOLLIN
.no_in:
        test    r13, AF_CURL_POLL_OUT
        jz      .no_out
        or      r14, EPOLLOUT
.no_out:
        test    r14, r14
        jz      .ok

        mov     rdi, [rbx + HE_LOOP]
        mov     rsi, r12
        call    af_loop_find_slot
        cmp     rax, 0
        jl      .add_it
        mov     rdi, [rbx + HE_LOOP]
        mov     rsi, r12
        mov     rdx, r14
        call    af_loop_mod
        test    rax, rax
        js      .bad
        jmp     .ok
.add_it:
        mov     rdi, [rbx + HE_LOOP]
        mov     rsi, r12
        mov     rdx, r14
        lea     rcx, [af_mcp_http_on_socket_event]
        mov     r8, rbx
        call    af_loop_add
        test    rax, rax
        js      .bad
        jmp     .ok

.remove:
        ; libcurl owns and closes the fd.  We only release the epoll slot.
        mov     rdi, [rbx + HE_LOOP]
        mov     rsi, r12
        call    af_loop_del
.ok:
        xor     eax, eax
        AF_LEAVE
.bad:
        mov     eax, -1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_http_on_timer(user, timeout_ms) -> i64
; ---------------------------------------------------------------------------
        global af_mcp_http_on_timer
af_mcp_http_on_timer:
        AF_ENTER 64
        test    rdi, rdi
        jz      .bad
        mov     rbx, rdi
        mov     r12, rsi
        cmp     qword [rbx + HE_TIMER_FD], 0
        jl      .bad

        lea     rdi, [rsp]
        mov     rsi, ITS_SIZE
        call    af_mem_zero
        cmp     r12, 0
        jl      .arm
        test    r12, r12
        jnz     .convert
        mov     qword [rsp + ITS_VALUE_NSEC], 1
        jmp     .arm
.convert:
        mov     rax, r12
        xor     edx, edx
        mov     rcx, 1000
        div     rcx
        mov     [rsp + ITS_VALUE_SEC], rax
        imul    rdx, rdx, NS_PER_MS
        mov     [rsp + ITS_VALUE_NSEC], rdx
.arm:
        mov     rdi, [rbx + HE_TIMER_FD]
        xor     esi, esi
        lea     rdx, [rsp]
        xor     ecx, ecx
        call    af_sys_timerfd_settime
        test    rax, rax
        js      .bad
        xor     eax, eax
        AF_LEAVE
.bad:
        mov     eax, -1
        AF_LEAVE

; ---------------------------------------------------------------------------
; Loop handlers for libcurl sockets and its timerfd.
; ---------------------------------------------------------------------------
        global af_mcp_http_on_socket_event
af_mcp_http_on_socket_event:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        xor     r14, r14
        test    r13, EPOLLIN
        jz      .event_no_in
        or      r14, AF_CURL_CSELECT_IN
.event_no_in:
        test    r13, EPOLLOUT
        jz      .event_no_out
        or      r14, AF_CURL_CSELECT_OUT
.event_no_out:
        test    r13, EPOLLERR | EPOLLHUP
        jz      .event_no_err
        or      r14, AF_CURL_CSELECT_ERR
.event_no_err:
        mov     rdi, [rbx + HE_MULTI]
        test    rdi, rdi
        jz      .done
        mov     rsi, r12
        mov     rdx, r14
        lea     rcx, [rbx + HE_RUNNING]
        call    af_curl_multi_socket_action
        movsxd  rax, eax
        mov     [rbx + HE_LAST_MULTI], rax
        test    eax, eax
        jz      .socket_reap
        inc     qword [rbx + HE_FAILED]
.socket_reap:
        mov     rdi, rbx
        call    af_mcp_http_reap
.done:
        AF_LEAVE

        global af_mcp_http_on_timer_event
af_mcp_http_on_timer_event:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
.drain:
        mov     rdi, [rbx + HE_TIMER_FD]
        lea     rsi, [rsp]
        mov     rdx, 8
        call    af_sys_read
        cmp     rax, 0
        jg      .drain

        mov     rdi, [rbx + HE_MULTI]
        test    rdi, rdi
        jz      .done
        lea     rsi, [rbx + HE_RUNNING]
        call    af_curl_multi_socket_timeout
        movsxd  rax, eax
        mov     [rbx + HE_LAST_MULTI], rax
        test    eax, eax
        jz      .timer_reap
        inc     qword [rbx + HE_FAILED]
.timer_reap:
        mov     rdi, rbx
        call    af_mcp_http_reap
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_http_reap(engine) -> void
;
; The hook consumes state synchronously and calls slot_release.  Reap itself
; deliberately does not release a valid slot, so the adapter can inspect the
; final response and clear its child pointers first.
; ---------------------------------------------------------------------------
        global af_mcp_http_reap
af_mcp_http_reap:
        AF_ENTER 48
; [rsp + 0] easy, [rsp + 8] curl result (dword), [rsp + 16] private xfer
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        cmp     qword [rbx + HE_MULTI], 0
        je      .done
.next:
        mov     qword [rsp], 0
        mov     dword [rsp + 8], 0
        mov     qword [rsp + 16], 0
        mov     rdi, [rbx + HE_MULTI]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        lea     rcx, [rsp + 16]
        call    af_curl_multi_next_done
        test    eax, eax
        jz      .done

        mov     r12, [rsp + 16]
        test    r12, r12
        jz      .orphan
        ; CURLOPT_PRIVATE is an internal pointer, but validate it before the
        ; first dereference so memory corruption cannot turn reap into a second
        ; out-of-bounds access.  Both range and exact slot alignment matter.
        lea     r14, [rbx + HE_TRANSFERS]
        cmp     r12, r14
        jb      .orphan
        lea     r15, [r14 + AF_MCP_HTTP_MAX_TRANSFERS * HX_SIZE]
        cmp     r12, r15
        jae     .orphan
        mov     rax, r12
        sub     rax, r14
        xor     edx, edx
        mov     ecx, HX_SIZE
        div     rcx
        test    rdx, rdx
        jnz     .orphan
        cmp     [r12 + HX_ENGINE], rbx
        jne     .orphan
        mov     rax, [rsp]
        cmp     [r12 + HX_EASY], rax
        jne     .orphan
        cmp     qword [r12 + HX_STATE], AF_MCP_HTTP_X_FREE
        je      .orphan

        movsxd  r13, dword [rsp + 8]
        test    qword [r12 + HX_FLAGS], AF_MCP_HTTP_F_CANCELLED
        jz      .result_ready
        ; A cancellation latched inside a curl callback reaches DONE only after
        ; that callback unwinds.  Preserve the same out-of-band result contract
        ; as synchronous cancellation rather than exposing CURLE_WRITE_ERROR.
        mov     r13, AF_MCP_HTTP_CURL_CANCELLED
.result_ready:
        mov     [r12 + HX_CURL_RESULT], r13
        mov     qword [r12 + HX_STATE], AF_MCP_HTTP_X_COMPLETING
        mov     rdi, [r12 + HX_EASY]
        call    af_curl_response_code
        mov     [r12 + HX_HTTP_STATUS], rax
        test    qword [r12 + HX_FLAGS], AF_MCP_HTTP_F_CANCELLED
        jnz     .notify
        test    r13, r13
        jnz     .count_failed
        inc     qword [rbx + HE_COMPLETED]
        jmp     .notify
.count_failed:
        inc     qword [rbx + HE_FAILED]
.notify:
        mov     rdi, r12
        mov     rsi, r13
        call    af_mcp_http_complete
        jmp     .next

.orphan:
        inc     qword [rbx + HE_FAILED]
        ; Recover by the easy handle before treating the completion as wholly
        ; unowned.  This covers a failed/corrupt PRIVATE lookup without leaving
        ; a table slot pointing at an easy handle freed behind its back.
        xor     r12, r12
.orphan_scan:
        cmp     r12, AF_MCP_HTTP_MAX_TRANSFERS
        jae     .unowned
        mov     r13, r12
        imul    r13, r13, HX_SIZE
        add     r13, rbx
        add     r13, HE_TRANSFERS
        cmp     qword [r13 + HX_STATE], AF_MCP_HTTP_X_FREE
        je      .orphan_next
        mov     rax, [rsp]
        cmp     [r13 + HX_EASY], rax
        jne     .orphan_next
        movsxd  r14, dword [rsp + 8]
        test    qword [r13 + HX_FLAGS], AF_MCP_HTTP_F_CANCELLED
        jz      .orphan_result_ready
        mov     r14, AF_MCP_HTTP_CURL_CANCELLED
.orphan_result_ready:
        mov     [r13 + HX_CURL_RESULT], r14
        cmp     qword [r13 + HX_CAUSE], 0
        jne     .orphan_notify
        mov     qword [r13 + HX_CAUSE], AF_E_INTERNAL
.orphan_notify:
        mov     qword [r13 + HX_STATE], AF_MCP_HTTP_X_COMPLETING
        mov     rdi, r13
        mov     rsi, r14
        call    af_mcp_http_complete
        jmp     .next
.orphan_next:
        inc     r12
        jmp     .orphan_scan
.unowned:
        mov     rdi, [rbx + HE_MULTI]
        mov     rsi, [rsp]
        call    af_curl_multi_remove
        mov     rdi, [rsp]
        call    af_curl_easy_free
        jmp     .next
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_http_slot_alloc(engine) -> af_mcp_http_transfer * (NULL when full)
;
; A successful slot already owns its MCP-specific easy handle and all bounded
; buffer descriptors.  Payload allocation remains lazy inside af_buffer.  The
; adapter configures the handle and publishes ACTIVE only after every borrowed
; curl pointer refers to slot-owned or retained storage.
; ---------------------------------------------------------------------------
        global af_mcp_http_slot_alloc
af_mcp_http_slot_alloc:
        AF_ENTER 32
        test    rdi, rdi
        jz      .none
        mov     rbx, rdi
        cmp     qword [rbx + HE_STARTED], 0
        je      .none
        cmp     qword [rbx + HE_MULTI], 0
        je      .none
        mov     rax, [rbx + HE_ACTIVE]
        cmp     rax, [rbx + HE_MAX_ACTIVE]
        jae     .none

        xor     r12, r12
.scan:
        cmp     r12, AF_MCP_HTTP_MAX_TRANSFERS
        jae     .none
        mov     r13, r12
        imul    r13, r13, HX_SIZE
        add     r13, rbx
        add     r13, HE_TRANSFERS
        cmp     qword [r13 + HX_STATE], AF_MCP_HTTP_X_FREE
        je      .found
        inc     r12
        jmp     .scan

.found:
        mov     rdi, r13
        mov     rsi, HX_SIZE
        call    af_mem_zero
        mov     qword [r13 + HX_STATE], AF_MCP_HTTP_X_BUILDING
        mov     [r13 + HX_ENGINE], rbx
        mov     [r13 + HX_SLOT], r12
        inc     qword [rbx + HE_ACTIVE]

        ; Clamp even an accidentally unvalidated engine override to the hard
        ; transport ceiling.  Zero selects the conservative default.
        mov     r14, [rbx + HE_HEADER_LIMIT]
        test    r14, r14
        jnz     .header_nonzero
        mov     r14, AF_MCP_HTTP_HEADER_DEFAULT
.header_nonzero:
        cmp     r14, AF_MCP_HTTP_HEADER_HARD_MAX
        jbe     .header_ready
        mov     r14, AF_MCP_HTTP_HEADER_HARD_MAX
.header_ready:
        mov     [r13 + HX_HEADER_LIMIT], r14

        mov     r14, [rbx + HE_BODY_LIMIT]
        test    r14, r14
        jnz     .body_nonzero
        mov     r14, AF_MCP_HTTP_BODY_DEFAULT
.body_nonzero:
        cmp     r14, AF_MCP_HTTP_BODY_HARD_MAX
        jbe     .body_ready
        mov     r14, AF_MCP_HTTP_BODY_HARD_MAX
.body_ready:
        mov     [r13 + HX_BODY_LIMIT], r14

        mov     r15, [rbx + HE_EVENT_LIMIT]
        test    r15, r15
        jnz     .event_nonzero
        mov     r15, AF_MCP_HTTP_EVENT_DEFAULT
.event_nonzero:
        cmp     r15, AF_MCP_HTTP_EVENT_HARD_MAX
        jbe     .event_ready
        mov     r15, AF_MCP_HTTP_EVENT_HARD_MAX
.event_ready:
        mov     [r13 + HX_EVENT_LIMIT], r15

        lea     rdi, [r13 + HX_BODY]
        mov     rsi, r14
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + HX_RESPONSE]
        mov     rsi, r14
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + HX_SSE_CARRY]
        mov     rsi, r14
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + HX_SSE_EVENT]
        mov     rsi, r15
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + HX_CONTENT_TYPE]
        mov     rsi, AF_MCP_HTTP_CTYPE_MAX
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + HX_PROTOCOL]
        mov     rsi, AF_MCP_HTTP_PROTOCOL_MAX
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + HX_SESSION]
        mov     rsi, AF_MCP_HTTP_SESSION_MAX
        call    af_buf_init
        test    rax, rax
        js      .fail
        lea     rdi, [r13 + HX_URL]
        mov     rsi, AF_MCP_HTTP_URL_MAX
        call    af_buf_init
        test    rax, rax
        js      .fail

        mov     rdi, r13
        call    af_curl_mcp_easy_new
        test    rax, rax
        jz      .fail
        mov     [r13 + HX_EASY], rax
        inc     qword [rbx + HE_TOTAL]
        mov     rax, r13
        AF_LEAVE

.fail:
        mov     rdi, r13
        call    af_mcp_http_slot_release
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_http_slot_release(x) -> void
;
; This is the sole owner teardown.  The order is mandatory: remove the easy
; handle from its multi, destroy it, destroy the slist it borrowed, wipe/free
; byte buffers, release the retained config snapshot, then zero/recycle slot.
; ---------------------------------------------------------------------------
        global af_mcp_http_slot_release
af_mcp_http_slot_release:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        cmp     qword [rbx + HX_STATE], AF_MCP_HTTP_X_FREE
        je      .done
        mov     r12, [rbx + HX_ENGINE]

        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_ADDED
        jz      .not_added
        test    r12, r12
        jz      .not_added
        mov     rdi, [r12 + HE_MULTI]
        test    rdi, rdi
        jz      .not_added
        mov     rsi, [rbx + HX_EASY]
        test    rsi, rsi
        jz      .not_added
        call    af_curl_multi_remove
.not_added:
        and     qword [rbx + HX_FLAGS], ~AF_MCP_HTTP_F_ADDED

        mov     rdi, [rbx + HX_EASY]
        test    rdi, rdi
        jz      .no_easy
        call    af_curl_easy_free
        mov     qword [rbx + HX_EASY], 0
.no_easy:
        mov     rdi, [rbx + HX_SLIST]
        test    rdi, rdi
        jz      .no_slist
        call    af_curl_slist_free
        mov     qword [rbx + HX_SLIST], 0
.no_slist:

        lea     rdi, [rbx + HX_BODY]
        call    af_buf_free_secure
        lea     rdi, [rbx + HX_RESPONSE]
        call    af_buf_free_secure
        lea     rdi, [rbx + HX_SSE_CARRY]
        call    af_buf_free_secure
        lea     rdi, [rbx + HX_SSE_EVENT]
        call    af_buf_free_secure
        lea     rdi, [rbx + HX_SESSION]
        call    af_buf_free_secure
        lea     rdi, [rbx + HX_URL]
        call    af_buf_free_secure
        lea     rdi, [rbx + HX_CONTENT_TYPE]
        call    af_buf_free
        lea     rdi, [rbx + HX_PROTOCOL]
        call    af_buf_free

        mov     rdi, [rbx + HX_CONFIG]
        test    rdi, rdi
        jz      .no_config
        call    af_config_release
        mov     qword [rbx + HX_CONFIG], 0
.no_config:
        mov     rdi, rbx
        mov     rsi, HX_SIZE
        call    af_mem_zero
        test    r12, r12
        jz      .done
        cmp     qword [r12 + HE_ACTIVE], 0
        je      .done
        dec     qword [r12 + HE_ACTIVE]
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_http_transfer_cancel(x, cause) -> void
;
; Outside a curl callback cancellation is synchronous: the policy hook sees a
; non-CURL sentinel plus HX_CAUSE and owns finalization.  During a callback we
; only latch cancellation; the callback aborts, and the DONE queue supplies the
; single completion notification after libcurl unwinds its own stack.
; ---------------------------------------------------------------------------
        global af_mcp_http_transfer_cancel
af_mcp_http_transfer_cancel:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        cmp     qword [rbx + HX_STATE], AF_MCP_HTTP_X_FREE
        je      .done
        cmp     qword [rbx + HX_STATE], AF_MCP_HTTP_X_COMPLETING
        je      .done
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CANCELLED
        jnz     .done

        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CANCELLED
        mov     [rbx + HX_CAUSE], rsi
        mov     qword [rbx + HX_CURL_RESULT], AF_MCP_HTTP_CURL_CANCELLED
        mov     r12, [rbx + HX_ENGINE]
        test    r12, r12
        jz      .counted
        inc     qword [r12 + HE_CANCELLED]
.counted:
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_IN_CALLBACK
        jz      .notify
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CANCEL_PENDING
        jmp     .done

.notify:
        mov     qword [rbx + HX_STATE], AF_MCP_HTTP_X_COMPLETING
        mov     rdi, rbx
        mov     rsi, AF_MCP_HTTP_CURL_CANCELLED
        call    af_mcp_http_complete
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_http_store_header_value(buffer, line, len, name_len) -> af_status
;
; Internal generic HTTP helper.  The caller has already matched the name; this
; routine still verifies the colon, trims optional whitespace and CR/LF, and
; copies into the destination buffer's own hard ceiling.
; ---------------------------------------------------------------------------
af_mcp_http_store_header_value:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
        cmp     r13, r14
        jbe     .invalid
        cmp     byte [r12 + r14], ':'
        jne     .invalid

        lea     r12, [r12 + r14 + 1]
        sub     r13, r14
        dec     r13
.trim_left:
        test    r13, r13
        jz      .trimmed
        movzx   eax, byte [r12]
        cmp     al, ' '
        je      .eat_left
        cmp     al, 9
        jne     .trim_right
.eat_left:
        inc     r12
        dec     r13
        jmp     .trim_left
.trim_right:
        test    r13, r13
        jz      .trimmed
        movzx   eax, byte [r12 + r13 - 1]
        cmp     al, 13
        je      .eat_right
        cmp     al, 10
        je      .eat_right
        cmp     al, ' '
        je      .eat_right
        cmp     al, 9
        jne     .trimmed
.eat_right:
        dec     r13
        jmp     .trim_right
.trimmed:
        mov     rdi, rbx
        call    af_buf_clear
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        call    af_buf_append
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_http_classify_content_type(x) -> void
;
; Transport classification only.  Parameters following the media type are
; allowed; adapter policy decides whether the resulting shape is acceptable.
; ---------------------------------------------------------------------------
af_mcp_http_classify_content_type:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        and     qword [rbx + HX_FLAGS], ~(AF_MCP_HTTP_F_CONTENT_JSON | AF_MCP_HTTP_F_CONTENT_SSE)
        lea     rdi, [rbx + HX_CONTENT_TYPE]
        call    af_buf_len
        mov     r13, rax
        test    r13, r13
        jz      .done
        lea     rdi, [rbx + HX_CONTENT_TYPE]
        call    af_buf_data
        mov     r12, rax
        test    r12, r12
        jz      .done

        cmp     r13, MHTTP_CTYPE_JSON_LEN
        jb      .maybe_sse
        mov     rdi, r12
        lea     rsi, [mhttp_ctype_json]
        mov     rdx, MHTTP_CTYPE_JSON_LEN
        call    af_mem_eq_ci
        test    rax, rax
        jz      .maybe_sse
        mov     rcx, MHTTP_CTYPE_JSON_LEN
.json_suffix:
        cmp     rcx, r13
        je      .is_json
        movzx   eax, byte [r12 + rcx]
        cmp     al, ' '
        je      .json_ows
        cmp     al, 9
        je      .json_ows
        cmp     al, ';'
        je      .is_json
        jmp     .maybe_sse
.json_ows:
        inc     rcx
        jmp     .json_suffix

.maybe_sse:
        cmp     r13, MHTTP_CTYPE_SSE_LEN
        jb      .done
        mov     rdi, r12
        lea     rsi, [mhttp_ctype_sse]
        mov     rdx, MHTTP_CTYPE_SSE_LEN
        call    af_mem_eq_ci
        test    rax, rax
        jz      .done
        mov     rcx, MHTTP_CTYPE_SSE_LEN
.sse_suffix:
        cmp     rcx, r13
        je      .is_sse
        movzx   eax, byte [r12 + rcx]
        cmp     al, ' '
        je      .sse_ows
        cmp     al, 9
        je      .sse_ows
        cmp     al, ';'
        je      .is_sse
        jmp     .done
.sse_ows:
        inc     rcx
        jmp     .sse_suffix
.is_sse:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CONTENT_SSE
        jmp     .done
.is_json:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CONTENT_JSON
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_http_on_header(user, at, len) -> i64
;
; Strictly bounded generic response metadata capture.  It intentionally does
; not validate an MCP protocol version, session semantics, or response shape.
; A new HTTP status line resets metadata from an interim response block.
; ---------------------------------------------------------------------------
        global af_mcp_http_on_header
af_mcp_http_on_header:
        AF_ENTER 48
        test    rdi, rdi
        jz      .abort_unmarked
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     [rsp], r13
        cmp     qword [rbx + HX_STATE], AF_MCP_HTTP_X_ACTIVE
        jne     .abort_unmarked
        test    r13, r13
        jz      .mark_callback
        test    r12, r12
        jz      .invalid_active

.mark_callback:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_IN_CALLBACK
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CANCELLED | AF_MCP_HTTP_F_CANCEL_PENDING
        jnz     .abort
        test    r13, r13
        jz      .accept

        mov     rax, [rbx + HX_HEADER_BYTES]
        add     rax, r13
        jc      .header_overflow
        cmp     rax, [rbx + HX_HEADER_LIMIT]
        ja      .header_limit
        mov     [rbx + HX_HEADER_BYTES], rax
        cmp     qword [rbx + HX_HEADER_LINES], -1
        je      .header_overflow
        inc     qword [rbx + HX_HEADER_LINES]

        cmp     r13, MHTTP_STATUS_PREFIX_LEN
        jb      .maybe_blank
        mov     rdi, r12
        lea     rsi, [mhttp_status_prefix]
        mov     rdx, MHTTP_STATUS_PREFIX_LEN
        call    af_mem_eq_ci
        test    rax, rax
        jz      .maybe_blank

        lea     rdi, [rbx + HX_CONTENT_TYPE]
        call    af_buf_clear
        lea     rdi, [rbx + HX_PROTOCOL]
        call    af_buf_clear
        lea     rdi, [rbx + HX_SESSION]
        call    af_buf_clear
        and     qword [rbx + HX_FLAGS], ~(AF_MCP_HTTP_F_HEADERS_DONE | AF_MCP_HTTP_F_CONTENT_JSON | AF_MCP_HTTP_F_CONTENT_SSE | AF_MCP_HTTP_F_CTYPE_SEEN | AF_MCP_HTTP_F_PROTOCOL_SEEN | AF_MCP_HTTP_F_SESSION_SEEN | AF_MCP_HTTP_F_DUP_HEADER)
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_STATUS_SEEN
        mov     qword [rbx + HX_HTTP_STATUS], 0
        jmp     .accept

.maybe_blank:
        cmp     r13, 2
        ja      .maybe_ctype
        movzx   eax, byte [r12]
        cmp     al, 13
        je      .headers_done
        cmp     al, 10
        jne     .maybe_ctype
.headers_done:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_HEADERS_DONE
        mov     rdi, [rbx + HX_EASY]
        test    rdi, rdi
        jz      .invalid_active
        call    af_curl_response_code
        mov     [rbx + HX_HTTP_STATUS], rax
        jmp     .accept

.maybe_ctype:
        ; libcurl also reports HTTP trailers through this callback.  They are
        ; bounded and counted above, but cannot replace protocol metadata from
        ; the completed header block.  A later redirect/proxy status line has
        ; already reset HEADERS_DONE before reaching here.
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_HEADERS_DONE
        jnz     .accept
        cmp     r13, MHTTP_H_CTYPE_LEN
        jbe     .maybe_protocol
        mov     rdi, r12
        lea     rsi, [mhttp_h_ctype]
        mov     rdx, MHTTP_H_CTYPE_LEN
        call    af_mem_eq_ci
        test    rax, rax
        jz      .maybe_protocol
        cmp     byte [r12 + MHTTP_H_CTYPE_LEN], ':'
        jne     .maybe_protocol
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CTYPE_SEEN
        jz      .ctype_first
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_DUP_HEADER
.ctype_first:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CTYPE_SEEN
        lea     rdi, [rbx + HX_CONTENT_TYPE]
        mov     rsi, r12
        mov     rdx, r13
        mov     rcx, MHTTP_H_CTYPE_LEN
        call    af_mcp_http_store_header_value
        test    rax, rax
        js      .store_failed
        mov     rdi, rbx
        call    af_mcp_http_classify_content_type
        jmp     .accept

.maybe_protocol:
        cmp     r13, MHTTP_H_PROTOCOL_LEN
        jbe     .maybe_session
        mov     rdi, r12
        lea     rsi, [mhttp_h_protocol]
        mov     rdx, MHTTP_H_PROTOCOL_LEN
        call    af_mem_eq_ci
        test    rax, rax
        jz      .maybe_session
        cmp     byte [r12 + MHTTP_H_PROTOCOL_LEN], ':'
        jne     .maybe_session
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_PROTOCOL_SEEN
        jz      .protocol_first
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_DUP_HEADER
.protocol_first:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_PROTOCOL_SEEN
        lea     rdi, [rbx + HX_PROTOCOL]
        mov     rsi, r12
        mov     rdx, r13
        mov     rcx, MHTTP_H_PROTOCOL_LEN
        call    af_mcp_http_store_header_value
        test    rax, rax
        js      .store_failed
        jmp     .accept

.maybe_session:
        cmp     r13, MHTTP_H_SESSION_LEN
        jbe     .accept
        mov     rdi, r12
        lea     rsi, [mhttp_h_session]
        mov     rdx, MHTTP_H_SESSION_LEN
        call    af_mem_eq_ci
        test    rax, rax
        jz      .accept
        cmp     byte [r12 + MHTTP_H_SESSION_LEN], ':'
        jne     .accept
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_SESSION_SEEN
        jz      .session_first
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_DUP_HEADER
.session_first:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_SESSION_SEEN
        lea     rdi, [rbx + HX_SESSION]
        mov     rsi, r12
        mov     rdx, r13
        mov     rcx, MHTTP_H_SESSION_LEN
        call    af_mcp_http_store_header_value
        test    rax, rax
        js      .store_failed
        jmp     .accept

.header_limit:
        mov     rax, AF_E_LIMIT
        jmp     .mark_overflow
.header_overflow:
        mov     rax, AF_E_OVERFLOW
.mark_overflow:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_OVERFLOW
        jmp     .record_failure
.store_failed:
        cmp     rax, AF_E_LIMIT
        je      .store_overflow
        cmp     rax, AF_E_OVERFLOW
        jne     .record_failure
.store_overflow:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_OVERFLOW
.record_failure:
        cmp     qword [rbx + HX_CAUSE], 0
        jne     .abort
        mov     [rbx + HX_CAUSE], rax
        jmp     .abort
.invalid_active:
        cmp     qword [rbx + HX_CAUSE], 0
        jne     .abort_maybe_marked
        mov     qword [rbx + HX_CAUSE], AF_E_INVALID
.abort_maybe_marked:
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_IN_CALLBACK
        jnz     .abort
.abort_unmarked:
        mov     rax, AF_CURL_TAKE_ABORT
        AF_LEAVE
.accept:
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CANCELLED | AF_MCP_HTTP_F_CANCEL_PENDING
        jnz     .abort
        and     qword [rbx + HX_FLAGS], ~AF_MCP_HTTP_F_IN_CALLBACK
        mov     rax, [rsp]
        AF_LEAVE
.abort:
        and     qword [rbx + HX_FLAGS], ~AF_MCP_HTTP_F_IN_CALLBACK
        mov     rax, AF_CURL_TAKE_ABORT
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_http_on_write(user, at, len) -> i64
;
; Body bytes are accumulated only in bounded slot-owned storage.  The adapter
; parses request-scoped SSE from HX_SSE_CARRY at completion and enforces the
; separate HX_EVENT_LIMIT while decoding; legacy advisory GETs are finite at
; HX_BODY_LIMIT and may be reopened by policy after completion.  JSON-RPC and
; reopen semantics stay outside this transport reactor.
; ---------------------------------------------------------------------------
        global af_mcp_http_on_write
af_mcp_http_on_write:
        AF_ENTER 32
        test    rdi, rdi
        jz      .abort_unmarked
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     [rsp], r13
        cmp     qword [rbx + HX_STATE], AF_MCP_HTTP_X_ACTIVE
        jne     .abort_unmarked
        test    r13, r13
        jz      .mark_callback
        test    r12, r12
        jz      .invalid_active
.mark_callback:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_IN_CALLBACK
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CANCELLED | AF_MCP_HTTP_F_CANCEL_PENDING
        jnz     .abort
        test    r13, r13
        jz      .accept

        mov     rax, [rbx + HX_BODY_BYTES]
        add     rax, r13
        jc      .body_overflow
        cmp     rax, [rbx + HX_BODY_LIMIT]
        ja      .body_limit
        mov     [rbx + HX_BODY_BYTES], rax

        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CONTENT_SSE
        jz      .json_body
        lea     rdi, [rbx + HX_SSE_CARRY]
        jmp     .append
.json_body:
        lea     rdi, [rbx + HX_RESPONSE]
.append:
        mov     rsi, r12
        mov     rdx, r13
        call    af_buf_append
        test    rax, rax
        js      .append_failed
        jmp     .accept

.body_limit:
        mov     rax, AF_E_LIMIT
        jmp     .mark_overflow
.body_overflow:
        mov     rax, AF_E_OVERFLOW
.mark_overflow:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_OVERFLOW
        jmp     .record_failure
.append_failed:
        cmp     rax, AF_E_LIMIT
        je      .append_overflow
        cmp     rax, AF_E_OVERFLOW
        jne     .record_failure
.append_overflow:
        or      qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_OVERFLOW
.record_failure:
        cmp     qword [rbx + HX_CAUSE], 0
        jne     .abort
        mov     [rbx + HX_CAUSE], rax
        jmp     .abort
.invalid_active:
        cmp     qword [rbx + HX_CAUSE], 0
        jne     .abort_maybe_marked
        mov     qword [rbx + HX_CAUSE], AF_E_INVALID
.abort_maybe_marked:
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_IN_CALLBACK
        jnz     .abort
.abort_unmarked:
        mov     rax, AF_CURL_TAKE_ABORT
        AF_LEAVE
.accept:
        test    qword [rbx + HX_FLAGS], AF_MCP_HTTP_F_CANCELLED | AF_MCP_HTTP_F_CANCEL_PENDING
        jnz     .abort
        and     qword [rbx + HX_FLAGS], ~AF_MCP_HTTP_F_IN_CALLBACK
        mov     rax, [rsp]
        AF_LEAVE
.abort:
        and     qword [rbx + HX_FLAGS], ~AF_MCP_HTTP_F_IN_CALLBACK
        mov     rax, AF_CURL_TAKE_ABORT
        AF_LEAVE
