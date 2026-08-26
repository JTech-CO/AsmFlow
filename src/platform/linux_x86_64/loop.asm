; AsmFlow — the single event loop.
;
; ADR 0002 and ARCHITECTURE.md 2: one loop, one thread, no shared writable
; memory. Every file descriptor the daemon owns — the control socket, the data
; plane listener, MCP child pipes, and libcurl's own sockets — is registered
; here, and every callback runs to completion before the next one starts. That
; is what makes "single owner" a property of the code rather than a convention.
;
; The source table is indexed by slot, and epoll carries the slot index in its
; data word rather than a pointer. A stale event for a descriptor that was
; closed and whose slot was reused would then dispatch to the new owner, so the
; slot also stores the fd and the dispatcher checks it: an event whose fd no
; longer matches its slot is dropped rather than delivered to the wrong handler.

        bits 64
        default rel

%include "asmflow.inc"
%include "loop.inc"

        extern af_mem_zero
        extern af_sys_epoll_create1
        extern af_sys_epoll_ctl
        extern af_sys_epoll_wait
        extern af_sys_close
        extern af_status_from_errno

        section .text

; ---------------------------------------------------------------------------
; af_loop_init(af_loop *loop) -> af_status
;
; Ownership: `loop` is caller-supplied storage; the loop owns only its epoll
; descriptor.
; ---------------------------------------------------------------------------
        global af_loop_init
af_loop_init:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, rbx
        mov     rsi, LOOP_SIZE
        call    af_mem_zero

        ; Mark every slot free. Zero is a valid descriptor, so the free marker
        ; has to be -1.
        xor     r12, r12
.clear:
        cmp     r12, AF_LOOP_MAX_SOURCES
        jae     .cleared
        mov     rax, r12
        imul    rax, rax, SRC_SIZE
        add     rax, rbx
        add     rax, LOOP_SOURCES
        mov     qword [rax + SRC_FD], -1
        inc     r12
        jmp     .clear
.cleared:
        mov     qword [rbx + LOOP_EPFD], -1

        mov     edi, EPOLL_CLOEXEC
        call    af_sys_epoll_create1
        test    rax, rax
        js      .syscall_failed
        mov     [rbx + LOOP_EPFD], rax
        AF_LEAVE_OK
.syscall_failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_loop_close(af_loop *loop) -> void
;
; Closes the epoll descriptor only. Registered descriptors belong to whoever
; registered them; closing them here would double-close whatever the owner
; closes on its own teardown path.
; ---------------------------------------------------------------------------
        global af_loop_close
af_loop_close:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, [rbx + LOOP_EPFD]
        cmp     rdi, 0
        jl      .done
        call    af_sys_close
        mov     qword [rbx + LOOP_EPFD], -1
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_loop_find_slot(af_loop *loop, i64 fd) -> i64 (slot index, or -1)
; ---------------------------------------------------------------------------
        global af_loop_find_slot
af_loop_find_slot:
        xor     ecx, ecx
.loop:
        cmp     rcx, AF_LOOP_MAX_SOURCES
        jae     .none
        mov     rax, rcx
        imul    rax, rax, SRC_SIZE
        add     rax, rdi
        add     rax, LOOP_SOURCES
        cmp     [rax + SRC_FD], rsi
        je      .found
        inc     rcx
        jmp     .loop
.found:
        mov     rax, rcx
        ret
.none:
        mov     rax, -1
        ret

; ---------------------------------------------------------------------------
; af_loop_add(af_loop *loop, i64 fd, u64 events, void *handler, void *ctx)
;   -> af_status
;
; Ownership: `ctx` is BORROWED and must outlive the registration. The loop never
; frees it.
; ---------------------------------------------------------------------------
        global af_loop_add
af_loop_add:
        AF_ENTER 48
        test    rdi, rdi
        jz      .invalid
        cmp     rsi, 0
        jl      .invalid
        test    rcx, rcx
        jz      .invalid
        mov     rbx, rdi                ; loop
        mov     r12, rsi                ; fd
        mov     r13, rdx                ; events
        mov     r14, rcx                ; handler
        mov     r15, r8                 ; ctx

        ; Registering the same descriptor twice would leave two slots claiming
        ; it, and the second close would dispatch to a slot that no longer owns
        ; anything.
        mov     rdi, rbx
        mov     rsi, r12
        call    af_loop_find_slot
        cmp     rax, 0
        jge     .already

        mov     rdi, rbx
        mov     rsi, -1
        call    af_loop_find_slot
        cmp     rax, 0
        jl      .full
        mov     [rsp], rax              ; slot index

        mov     rax, [rsp]
        imul    rax, rax, SRC_SIZE
        add     rax, rbx
        add     rax, LOOP_SOURCES
        mov     [rax + SRC_FD], r12
        mov     [rax + SRC_HANDLER], r14
        mov     [rax + SRC_CTX], r15
        mov     [rax + SRC_EVENTS], r13

        ; The data word carries the slot index, not a pointer: an index can be
        ; validated against the table, a stale pointer cannot.
        mov     eax, r13d
        mov     [rsp + 16], eax                     ; events
        mov     rax, [rsp]
        mov     [rsp + 16 + EPOLL_EVENT_DATA], rax  ; data = slot

        mov     rdi, [rbx + LOOP_EPFD]
        mov     rsi, EPOLL_CTL_ADD
        mov     rdx, r12
        lea     rcx, [rsp + 16]
        call    af_sys_epoll_ctl
        test    rax, rax
        js      .ctl_failed
        AF_LEAVE_OK

.ctl_failed:
        mov     [rsp + 8], rax
        mov     rax, [rsp]
        imul    rax, rax, SRC_SIZE
        add     rax, rbx
        add     rax, LOOP_SOURCES
        mov     qword [rax + SRC_FD], -1
        mov     rdi, [rsp + 8]
        call    af_status_from_errno
        AF_LEAVE
.already:
        AF_LEAVE_ERR AF_E_EXISTS
.full:
        AF_LEAVE_ERR AF_E_LIMIT
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_loop_mod(af_loop *loop, i64 fd, u64 events) -> af_status
;
; Used for backpressure: a connection with nothing to write drops EPOLLOUT so
; the loop is not woken for a socket it has nothing to say to.
; ---------------------------------------------------------------------------
        global af_loop_mod
af_loop_mod:
        AF_ENTER 48
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, rbx
        mov     rsi, r12
        call    af_loop_find_slot
        cmp     rax, 0
        jl      .notfound
        mov     [rsp], rax

        mov     rax, [rsp]
        imul    rax, rax, SRC_SIZE
        add     rax, rbx
        add     rax, LOOP_SOURCES
        mov     [rax + SRC_EVENTS], r13

        mov     eax, r13d
        mov     [rsp + 16], eax
        mov     rax, [rsp]
        mov     [rsp + 16 + EPOLL_EVENT_DATA], rax

        mov     rdi, [rbx + LOOP_EPFD]
        mov     rsi, EPOLL_CTL_MOD
        mov     rdx, r12
        lea     rcx, [rsp + 16]
        call    af_sys_epoll_ctl
        test    rax, rax
        js      .ctl_failed
        AF_LEAVE_OK
.ctl_failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.notfound:
        AF_LEAVE_ERR AF_E_NOTFOUND

; ---------------------------------------------------------------------------
; af_loop_del(af_loop *loop, i64 fd) -> af_status
;
; Deregisters without closing. The caller closes, in that order: a descriptor
; closed while still registered is removed from the interest set by the kernel,
; but any event already queued for it would still be delivered.
; ---------------------------------------------------------------------------
        global af_loop_del
af_loop_del:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, rbx
        mov     rsi, r12
        call    af_loop_find_slot
        cmp     rax, 0
        jl      .notfound
        imul    rax, rax, SRC_SIZE
        add     rax, rbx
        add     rax, LOOP_SOURCES
        mov     qword [rax + SRC_FD], -1
        mov     qword [rax + SRC_HANDLER], 0
        mov     qword [rax + SRC_CTX], 0

        mov     rdi, [rbx + LOOP_EPFD]
        mov     rsi, EPOLL_CTL_DEL
        mov     rdx, r12
        lea     rcx, [rsp]
        call    af_sys_epoll_ctl
        ; EPOLL_CTL_DEL on a descriptor the kernel already dropped is not an
        ; error worth propagating: the slot is free either way.
        AF_LEAVE_OK
.notfound:
        AF_LEAVE_ERR AF_E_NOTFOUND

; ---------------------------------------------------------------------------
; af_loop_step(af_loop *loop, i64 timeout_ms, u64 *out_dispatched)
;   -> af_status
;
; One epoll_wait and the dispatch of whatever it returned. Separated from
; af_loop_run so a test can drive the loop deterministically, one batch at a
; time, instead of starting a thread and hoping.
; ---------------------------------------------------------------------------
        global af_loop_step
af_loop_step:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi                ; loop
        mov     r12, rsi                ; timeout
        mov     r13, rdx                ; out count
        test    r13, r13
        jz      .no_out
        mov     qword [r13], 0
.no_out:

        mov     rdi, [rbx + LOOP_EPFD]
        lea     rsi, [rbx + LOOP_EVENTS]
        mov     rdx, AF_LOOP_BATCH
        mov     rcx, r12
        call    af_sys_epoll_wait
        test    rax, rax
        js      .wait_failed
        mov     [rsp], rax              ; number of events
        inc     qword [rbx + LOOP_ITERS]

        xor     r14, r14
.dispatch:
        cmp     r14, [rsp]
        jae     .dispatched
        mov     rax, r14
        imul    rax, rax, EPOLL_EVENT_SIZE
        lea     r15, [rbx + LOOP_EVENTS]
        add     r15, rax
        mov     eax, [r15 + EPOLL_EVENT_EVENTS]
        mov     [rsp + 8], rax                      ; event mask
        mov     rax, [r15 + EPOLL_EVENT_DATA]
        mov     [rsp + 16], rax                     ; slot index

        ; A slot index out of range would mean the kernel returned data we
        ; never set.
        cmp     rax, AF_LOOP_MAX_SOURCES
        jae     .next
        imul    rax, rax, SRC_SIZE
        add     rax, rbx
        add     rax, LOOP_SOURCES
        mov     rcx, [rax + SRC_FD]
        cmp     rcx, 0
        jl      .next                   ; the slot was released mid-batch
        mov     rdx, [rax + SRC_HANDLER]
        test    rdx, rdx
        jz      .next
        mov     rdi, [rax + SRC_CTX]
        mov     rsi, rcx
        mov     [rsp + 24], rdx
        mov     rdx, [rsp + 8]
        call    [rsp + 24]

        test    r13, r13
        jz      .next
        inc     qword [r13]
.next:
        inc     r14
        jmp     .dispatch

.dispatched:
        AF_LEAVE_OK
.wait_failed:
        mov     rdi, rax
        call    af_status_from_errno
        ; A signal during the wait is not a failure; the caller loops again.
        cmp     rax, AF_E_INTR
        jne     .propagate
        AF_LEAVE_OK
.propagate:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_loop_run(af_loop *loop, i64 timeout_ms) -> af_status
;
; Steps until af_loop_stop is called or a step fails.
; ---------------------------------------------------------------------------
        global af_loop_run
af_loop_run:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     qword [rbx + LOOP_RUNNING], 1
        ; The stop flag is deliberately NOT cleared here. A stop requested
        ; before the loop starts — a signal that arrived during startup, a
        ; failure that decided to shut down — must be honoured, not erased by
        ; the run it was meant to prevent.
.loop:
        cmp     qword [rbx + LOOP_STOP], 0
        jne     .stopped
        mov     rdi, rbx
        mov     rsi, r12
        lea     rdx, [rsp]
        call    af_loop_step
        test    rax, rax
        js      .failed
        jmp     .loop
.stopped:
        mov     qword [rbx + LOOP_RUNNING], 0
        AF_LEAVE_OK
.failed:
        mov     qword [rbx + LOOP_RUNNING], 0
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_loop_stop(af_loop *loop) -> void
;
; Requests a stop after the current batch finishes. Safe from inside a handler:
; the running batch completes so no half-processed connection is abandoned.
; ---------------------------------------------------------------------------
        global af_loop_stop
af_loop_stop:
        test    rdi, rdi
        jz      .done
        mov     qword [rdi + LOOP_STOP], 1
.done:
        ret

        global af_loop_is_running
af_loop_is_running:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + LOOP_RUNNING]
.done:
        ret

        global af_loop_iterations
af_loop_iterations:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + LOOP_ITERS]
.done:
        ret

; ---------------------------------------------------------------------------
; af_loop_source_count(af_loop *loop) -> u64
; ---------------------------------------------------------------------------
        global af_loop_source_count
af_loop_source_count:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        xor     ecx, ecx
        xor     edx, edx
.count:
        cmp     rcx, AF_LOOP_MAX_SOURCES
        jae     .finished
        mov     rax, rcx
        imul    rax, rax, SRC_SIZE
        add     rax, rdi
        add     rax, LOOP_SOURCES
        cmp     qword [rax + SRC_FD], 0
        jl      .skip
        inc     rdx
.skip:
        inc     rcx
        jmp     .count
.finished:
        mov     rax, rdx
.done:
        ret

        global af_loop_struct_size
af_loop_struct_size:
        mov     eax, LOOP_SIZE
        ret
