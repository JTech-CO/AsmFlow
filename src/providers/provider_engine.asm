; AsmFlow — the upstream engine: libcurl's multi interface inside our loop.
;
; ADR 0011. libcurl offers three ways to run the multi interface. Two of them
; own the wait: `curl_multi_wait` and `curl_multi_perform` both block, and both
; would make libcurl the reactor. AsmFlow already has one (ADR 0002), and a
; daemon with two event loops has no single place where "what is this process
; waiting for" can be answered. The third way — `curl_multi_socket_action` with
; a socket callback and a timer callback — hands those two questions back to
; the embedder, and that is the one used here.
;
; The shape is small once stated:
;
;   libcurl says "watch fd 9 for readable"     -> af_loop_add / af_loop_mod
;   libcurl says "stop watching fd 9"          -> af_loop_del
;   libcurl says "call me back in 200ms"       -> arm the timerfd
;   the loop reports fd 9 readable             -> curl_multi_socket_action
;   the loop reports the timerfd readable      -> curl_multi_socket_action
;   after either, drain the completion queue   -> af_prov_reap
;
; Two rules in here are not obvious and are load-bearing.
;
; The descriptors libcurl hands us are libcurl's. `af_loop_del` deregisters
; without closing for exactly this reason: closing one would take a connection
; out from under a live transfer, and the fault would surface as a corrupt
; response on some *other* request that reused the descriptor number.
;
; A timer callback asking for 0ms is asking to be called back immediately, and
; libcurl forbids re-entering `curl_multi_socket_action` from inside a callback
; it is currently making. Arming the timerfd for one nanosecond expresses
; "immediately" without re-entering: the loop delivers it on the next turn.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "loop.inc"
%include "socket.inc"
%include "runtime.inc"
%include "config.inc"
%include "http.inc"
%include "provider.inc"

        extern af_mem_zero

        extern af_loop_add
        extern af_loop_mod
        extern af_loop_del
        extern af_loop_find_slot

        extern af_sys_timerfd_create
        extern af_sys_timerfd_settime
        extern af_sys_close
        extern af_sys_read
        extern af_status_from_errno

        extern af_curl_global_init
        extern af_curl_global_cleanup
        extern af_curl_multi_new
        extern af_curl_multi_free
        extern af_curl_multi_add
        extern af_curl_multi_remove
        extern af_curl_multi_socket_action
        extern af_curl_multi_socket_timeout
        extern af_curl_multi_next_done
        extern af_curl_easy_free

        extern af_prov_check_ordinals
        extern af_prov_exchange_finish
        extern af_prov_exchange_abandon

        section .text

; ---------------------------------------------------------------------------
; af_prov_engine_init(af_prov_engine *e, af_loop *loop, af_runtime *rt)
;   -> af_status
;
; Everything that can fail happens here rather than on the first request: a
; libcurl whose enumerators do not match ours, or a timer descriptor the kernel
; will not give, is a reason not to start rather than a reason to fail the
; first client that arrives.
; ---------------------------------------------------------------------------
        global af_prov_engine_init
af_prov_engine_init:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     [rsp], rsi                      ; loop
        mov     [rsp + 8], rdx                  ; runtime

        mov     rdi, rbx
        mov     rsi, PE_SIZE
        call    af_mem_zero
        mov     qword [rbx + PE_TIMER_FD], -1

        ; The mirrored enumerators first: everything below this line assumes
        ; they are right, so a mismatch has to stop the daemon before any
        ; handle exists.
        call    af_prov_check_ordinals
        test    rax, rax
        js      .fail

        mov     rax, [rsp]
        mov     [rbx + PE_LOOP], rax
        mov     rax, [rsp + 8]
        mov     [rbx + PE_RT], rax

        call    af_curl_global_init
        test    eax, eax
        jnz     .curl_failed
        mov     qword [rbx + PE_STARTED], 1

        mov     rdi, rbx
        call    af_curl_multi_new
        test    rax, rax
        jz      .curl_failed
        mov     [rbx + PE_MULTI], rax

        ; The ceiling: whatever the operator configured, but never more slots
        ; than the table has. A configuration cannot enlarge a fixed array.
        mov     r12, AF_PROV_MAX_EXCHANGES
        mov     rax, [rsp + 8]
        test    rax, rax
        jz      .ceiling_ready
        mov     rax, [rax + RT_CONFIG]
        test    rax, rax
        jz      .ceiling_ready
        mov     rax, [rax + CFG_LIM_MAX_ACTIVE]
        test    rax, rax
        jz      .ceiling_ready
        cmp     rax, r12
        jae     .ceiling_ready
        mov     r12, rax
.ceiling_ready:
        mov     [rbx + PE_MAX_ACTIVE], r12

        ; The timer libcurl drives. Disarmed until libcurl asks for it.
        mov     rdi, CLOCK_MONOTONIC
        mov     rsi, TFD_NONBLOCK | TFD_CLOEXEC
        call    af_sys_timerfd_create
        test    rax, rax
        js      .syscall_failed
        mov     [rbx + PE_TIMER_FD], rax

        mov     rdi, [rbx + PE_LOOP]
        mov     rsi, [rbx + PE_TIMER_FD]
        mov     rdx, EPOLLIN
        lea     rcx, [af_prov_on_timer_event]
        mov     r8, rbx
        call    af_loop_add
        test    rax, rax
        js      .fail
        AF_LEAVE_OK

.curl_failed:
        mov     rax, AF_E_UNSUPPORTED
.fail:
        mov     [rsp + 16], rax
        mov     rdi, rbx
        call    af_prov_engine_shutdown
        mov     rax, [rsp + 16]
        AF_LEAVE
.syscall_failed:
        mov     rdi, rax
        call    af_status_from_errno
        jmp     .fail
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_prov_engine_shutdown(af_prov_engine *e) -> void
;
; Exchanges first, then the timer, then libcurl. An exchange still holding an
; easy handle when the multi handle goes would be a handle nobody removes, and
; libcurl's own cleanup would then free it while our table still points at it.
; ---------------------------------------------------------------------------
        global af_prov_engine_shutdown
af_prov_engine_shutdown:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi

        xor     r12, r12
.cancel_loop:
        cmp     r12, AF_PROV_MAX_EXCHANGES
        jae     .cancelled
        mov     rax, r12
        imul    rax, rax, PX_SIZE
        add     rax, rbx
        add     rax, PE_EXCHANGES
        cmp     qword [rax + PX_STATE], AF_PX_FREE
        je      .cancel_next
        mov     rdi, rax
        call    af_prov_exchange_abandon
.cancel_next:
        inc     r12
        jmp     .cancel_loop
.cancelled:

        cmp     qword [rbx + PE_TIMER_FD], 0
        jl      .timer_done
        mov     rdi, [rbx + PE_LOOP]
        test    rdi, rdi
        jz      .close_timer
        mov     rsi, [rbx + PE_TIMER_FD]
        call    af_loop_del
.close_timer:
        mov     rdi, [rbx + PE_TIMER_FD]
        call    af_sys_close
        mov     qword [rbx + PE_TIMER_FD], -1
.timer_done:

        mov     rdi, [rbx + PE_MULTI]
        test    rdi, rdi
        jz      .multi_done
        call    af_curl_multi_free
        mov     qword [rbx + PE_MULTI], 0
.multi_done:

        cmp     qword [rbx + PE_STARTED], 0
        je      .done
        call    af_curl_global_cleanup
        mov     qword [rbx + PE_STARTED], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_on_socket(void *user, i64 fd, i64 what) -> i64
;
; libcurl's socket callback. `user` is the engine. Returns 0 on success;
; anything else makes libcurl abandon the transfer set, which is why a
; registration failure is reported rather than swallowed.
; ---------------------------------------------------------------------------
        global af_prov_on_socket
af_prov_on_socket:
        AF_ENTER 32
        test    rdi, rdi
        jz      .bad
        mov     rbx, rdi
        mov     r12, rsi                        ; fd
        mov     r13, rdx                        ; what

        cmp     r13, AF_CURL_POLL_REMOVE
        je      .remove

        ; CURL_POLL_IN and CURL_POLL_OUT are 1 and 2, and INOUT is their sum;
        ; the mask is built from the bits rather than by comparing all three,
        ; so a value libcurl adds later degrades to "watch nothing" instead of
        ; to "watch the wrong thing".
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
        jz      .ok                             ; CURL_POLL_NONE: nothing to do

        mov     rdi, [rbx + PE_LOOP]
        mov     rsi, r12
        call    af_loop_find_slot
        cmp     rax, 0
        jl      .add_it
        mov     rdi, [rbx + PE_LOOP]
        mov     rsi, r12
        mov     rdx, r14
        call    af_loop_mod
        test    rax, rax
        js      .bad
        jmp     .ok
.add_it:
        mov     rdi, [rbx + PE_LOOP]
        mov     rsi, r12
        mov     rdx, r14
        lea     rcx, [af_prov_on_socket_event]
        mov     r8, rbx
        call    af_loop_add
        test    rax, rax
        js      .bad
        jmp     .ok

.remove:
        ; Deregister only. The descriptor belongs to libcurl, which will close
        ; it when the connection it belongs to is finished with.
        mov     rdi, [rbx + PE_LOOP]
        mov     rsi, r12
        call    af_loop_del
.ok:
        xor     eax, eax
        AF_LEAVE
.bad:
        mov     eax, -1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_on_timer(void *user, i64 timeout_ms) -> i64
;
; libcurl's timer callback. A negative timeout disarms; zero means "as soon as
; possible", which is expressed as one nanosecond rather than by calling back
; into libcurl from inside its own callback.
; ---------------------------------------------------------------------------
        global af_prov_on_timer
af_prov_on_timer:
        AF_ENTER 64
        test    rdi, rdi
        jz      .bad
        mov     rbx, rdi
        mov     r12, rsi

        cmp     qword [rbx + PE_TIMER_FD], 0
        jl      .bad

        lea     rdi, [rsp]
        mov     rsi, ITS_SIZE
        call    af_mem_zero

        cmp     r12, 0
        jl      .arm                            ; all zero disarms the timer
        test    r12, r12
        jnz     .convert
        mov     qword [rsp + ITS_VALUE_NSEC], 1
        jmp     .arm
.convert:
        ; milliseconds -> (seconds, nanoseconds)
        mov     rax, r12
        xor     edx, edx
        mov     rcx, 1000
        div     rcx                             ; rax = seconds, rdx = ms left
        mov     [rsp + ITS_VALUE_SEC], rax
        imul    rdx, rdx, NS_PER_MS
        mov     [rsp + ITS_VALUE_NSEC], rdx
.arm:
        mov     rdi, [rbx + PE_TIMER_FD]
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
; af_prov_on_socket_event(void *ctx, i64 fd, u64 events) -> void
;
; A loop source libcurl asked for became ready.
; ---------------------------------------------------------------------------
        global af_prov_on_socket_event
af_prov_on_socket_event:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx

        xor     r14, r14
        test    r13, EPOLLIN
        jz      .no_in
        or      r14, AF_CURL_CSELECT_IN
.no_in:
        test    r13, EPOLLOUT
        jz      .no_out
        or      r14, AF_CURL_CSELECT_OUT
.no_out:
        test    r13, EPOLLERR | EPOLLHUP
        jz      .no_err
        or      r14, AF_CURL_CSELECT_ERR
.no_err:

        mov     rdi, [rbx + PE_MULTI]
        test    rdi, rdi
        jz      .done
        mov     rsi, r12
        mov     rdx, r14
        lea     rcx, [rbx + PE_RUNNING]
        call    af_curl_multi_socket_action

        mov     rdi, rbx
        call    af_prov_reap
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_on_timer_event(void *ctx, i64 fd, u64 events) -> void
;
; The timerfd libcurl armed has expired. Draining it first matters: a timerfd
; left unread stays readable, and the loop would spin.
; ---------------------------------------------------------------------------
        global af_prov_on_timer_event
af_prov_on_timer_event:
        AF_ENTER 32
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi

.drain:
        mov     rdi, [rbx + PE_TIMER_FD]
        lea     rsi, [rsp]
        mov     rdx, 8
        call    af_sys_read
        cmp     rax, 0
        jg      .drain

        mov     rdi, [rbx + PE_MULTI]
        test    rdi, rdi
        jz      .done
        lea     rsi, [rbx + PE_RUNNING]
        call    af_curl_multi_socket_timeout

        mov     rdi, rbx
        call    af_prov_reap
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_reap(af_prov_engine *e) -> void
;
; Hand every finished transfer to its exchange. libcurl's completion queue is
; drained fully rather than one per turn: a message left in it is a client left
; waiting on a transfer that has already ended.
; ---------------------------------------------------------------------------
        global af_prov_reap
af_prov_reap:
        AF_ENTER 48
;   [rsp +  0]  easy handle    [rsp + 16]  private pointer (the exchange)
;   [rsp +  8]  curl result
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        cmp     qword [rbx + PE_MULTI], 0
        je      .done
.next:
        mov     qword [rsp], 0
        mov     dword [rsp + 8], 0
        mov     qword [rsp + 16], 0
        mov     rdi, [rbx + PE_MULTI]
        lea     rsi, [rsp]
        lea     rdx, [rsp + 8]
        lea     rcx, [rsp + 16]
        call    af_curl_multi_next_done
        test    eax, eax
        jz      .done

        mov     rdi, [rsp + 16]
        test    rdi, rdi
        jz      .orphan
        movsxd  rsi, dword [rsp + 8]
        call    af_prov_exchange_finish
        jmp     .next

.orphan:
        ; A finished handle with no exchange behind it should not exist. If one
        ; ever does, it is removed and freed rather than left in the multi
        ; handle, because the alternative is a transfer that completes forever.
        mov     rdi, [rbx + PE_MULTI]
        mov     rsi, [rsp]
        call    af_curl_multi_remove
        mov     rdi, [rsp]
        call    af_curl_easy_free
        jmp     .next
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_slot_alloc(af_prov_engine *e) -> af_prov_exchange * (NULL when full)
;
; Linear over a table of sixty-four. A free-list would be faster and would also
; be a second representation of "which slots are in use" that could disagree
; with the states in the table.
; ---------------------------------------------------------------------------
        global af_prov_slot_alloc
af_prov_slot_alloc:
        AF_ENTER 16
        test    rdi, rdi
        jz      .none
        mov     rbx, rdi

        mov     rax, [rbx + PE_ACTIVE]
        cmp     rax, [rbx + PE_MAX_ACTIVE]
        jae     .none

        xor     r12, r12
.scan:
        cmp     r12, AF_PROV_MAX_EXCHANGES
        jae     .none
        mov     r13, r12
        imul    r13, r13, PX_SIZE
        add     r13, rbx
        add     r13, PE_EXCHANGES
        cmp     qword [r13 + PX_STATE], AF_PX_FREE
        je      .found
        inc     r12
        jmp     .scan
.found:
        mov     rdi, r13
        mov     rsi, PX_SIZE
        call    af_mem_zero
        mov     qword [r13 + PX_STATE], AF_PX_STARTING
        mov     [r13 + PX_ENGINE], rbx
        mov     [r13 + PX_SLOT], r12
        inc     qword [rbx + PE_ACTIVE]
        inc     qword [rbx + PE_TOTAL]
        mov     rax, r13
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_prov_slot_release(af_prov_exchange *x) -> void
;
; Returns the slot after the exchange has already given up its handles. Zeroing
; the whole record rather than only the state field means a stale pointer in a
; reused slot cannot be read as a live one.
; ---------------------------------------------------------------------------
        global af_prov_slot_release
af_prov_slot_release:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        cmp     qword [rbx + PX_STATE], AF_PX_FREE
        je      .done
        mov     r12, [rbx + PX_ENGINE]
        mov     rdi, rbx
        mov     rsi, PX_SIZE
        call    af_mem_zero
        test    r12, r12
        jz      .done
        cmp     qword [r12 + PE_ACTIVE], 0
        je      .done
        dec     qword [r12 + PE_ACTIVE]
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; Accessors, so a test can assert the layout rather than restate it.
; ---------------------------------------------------------------------------
        global af_prov_engine_struct_size
af_prov_engine_struct_size:
        mov     rax, PE_SIZE
        ret

        global af_prov_exchange_struct_size
af_prov_exchange_struct_size:
        mov     rax, PX_SIZE
        ret

        global af_prov_engine_active
af_prov_engine_active:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + PE_ACTIVE]
        ret
.zero:
        xor     eax, eax
        ret

        global af_prov_engine_total
af_prov_engine_total:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + PE_TOTAL]
        ret
.zero:
        xor     eax, eax
        ret

        global af_prov_engine_max_active
af_prov_engine_max_active:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + PE_MAX_ACTIVE]
        ret
.zero:
        xor     eax, eax
        ret
