; AsmFlow — signal delivery as an event-loop source.
;
; A conventional signal handler runs at an arbitrary point in the program and
; may call only async-signal-safe functions. In a daemon that owns a SQLite
; handle, libcurl state, and child processes, almost nothing it would want to do
; is on that list, and the usual workaround — set a flag, check it later — still
; needs the loop to wake up.
;
; signalfd removes the problem instead of working around it. The signals are
; blocked, so no handler ever runs; they queue, and reading the descriptor turns
; each one into an ordinary event the loop dispatches like any other. Shutdown
; then runs on the normal path, with the whole runtime available.
;
; SIGPIPE is blocked for a different reason: writing to a socket whose peer has
; gone would otherwise kill the process. Blocked, the write returns EPIPE and the
; connection is closed the same way every other failure is.

        bits 64
        default rel

%include "asmflow.inc"

        extern af_sys_rt_sigprocmask
        extern af_sys_signalfd4
        extern af_sys_read
        extern af_sys_close
        extern af_status_from_errno
        extern af_mem_zero

%define SIG_BLOCK   0
%define SIG_SETMASK 2

%define SIGINT   2
%define SIGQUIT  3
%define SIGPIPE  13
%define SIGTERM  15
%define SIGHUP   1
%define SIGCHLD  17

%define SFD_NONBLOCK 0x800
%define SFD_CLOEXEC  0x80000

; struct signalfd_siginfo is 128 bytes; ssi_signo is its first field.
%define SIGINFO_SIZE  128
%define SIGINFO_SIGNO 0

        section .text

; ---------------------------------------------------------------------------
; af_signal_mask_build(u64 *out_mask) -> void
;
; The set the daemon takes over: termination, reload, child exit, and the pipe
; signal. Everything else keeps its default disposition, because a daemon that
; swallowed SIGSEGV would hide the defect the crash tests exist to surface.
; ---------------------------------------------------------------------------
        global af_signal_mask_build
af_signal_mask_build:
        xor     eax, eax
        bts     rax, SIGINT - 1
        bts     rax, SIGTERM - 1
        bts     rax, SIGHUP - 1
        bts     rax, SIGQUIT - 1
        bts     rax, SIGPIPE - 1
        bts     rax, SIGCHLD - 1
        mov     [rdi], rax
        ret

; ---------------------------------------------------------------------------
; af_signals_block(const u64 *mask, u64 *out_previous) -> af_status
;
; Must run before the descriptor is created and before any thread could be
; started: a signal delivered in the gap would take its default action.
; ---------------------------------------------------------------------------
        global af_signals_block
af_signals_block:
        AF_ENTER 0
        mov     rdx, rsi                ; oldset (may be NULL)
        mov     rsi, rdi                ; the set to block
        mov     edi, SIG_BLOCK
        mov     rcx, 8                  ; the kernel's sigset_t size
        call    af_sys_rt_sigprocmask
        test    rax, rax
        js      .failed
        AF_LEAVE_OK
.failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_signals_restore(const u64 *mask) -> af_status
; ---------------------------------------------------------------------------
        global af_signals_restore
af_signals_restore:
        AF_ENTER 0
        mov     rsi, rdi
        mov     edi, SIG_SETMASK
        xor     edx, edx
        mov     rcx, 8
        call    af_sys_rt_sigprocmask
        test    rax, rax
        js      .failed
        AF_LEAVE_OK
.failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_signalfd_open(const u64 *mask, i64 *out_fd) -> af_status
; ---------------------------------------------------------------------------
        global af_signalfd_open
af_signalfd_open:
        AF_ENTER 0
        mov     rbx, rsi
        mov     qword [rbx], -1
        mov     rsi, rdi
        mov     rdi, -1                 ; create a new descriptor
        mov     rdx, 8
        mov     rcx, SFD_NONBLOCK | SFD_CLOEXEC
        call    af_sys_signalfd4
        test    rax, rax
        js      .failed
        mov     [rbx], rax
        AF_LEAVE_OK
.failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_signalfd_next(i64 fd, i64 *out_signo) -> af_status
;
; AF_E_AGAIN when the queue is empty. One signal per call, so a caller drains in
; a loop and cannot miss a second SIGTERM that arrived while it handled the
; first.
; ---------------------------------------------------------------------------
        global af_signalfd_next
af_signalfd_next:
        AF_ENTER 144
        mov     rbx, rsi
        mov     qword [rbx], 0
        mov     rsi, rsp
        mov     rdx, SIGINFO_SIZE
        call    af_sys_read
        test    rax, rax
        js      .failed
        cmp     rax, SIGINFO_SIZE
        jb      .short_read
        mov     eax, [rsp + SIGINFO_SIGNO]
        mov     [rbx], rax
        AF_LEAVE_OK
.short_read:
        AF_LEAVE_ERR AF_E_INTERNAL
.failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_signal_is_termination(i64 signo) -> i64 (1 = shut down)
; ---------------------------------------------------------------------------
        global af_signal_is_termination
af_signal_is_termination:
        xor     eax, eax
        cmp     rdi, SIGTERM
        je      .yes
        cmp     rdi, SIGINT
        je      .yes
        cmp     rdi, SIGQUIT
        je      .yes
        ret
.yes:
        mov     eax, 1
        ret

; ---------------------------------------------------------------------------
; af_signal_is_reload(i64 signo) -> i64 (1 = reload configuration)
; ---------------------------------------------------------------------------
        global af_signal_is_reload
af_signal_is_reload:
        xor     eax, eax
        cmp     rdi, SIGHUP
        jne     .done
        mov     eax, 1
.done:
        ret

        global af_signal_sigterm
af_signal_sigterm:
        mov     eax, SIGTERM
        ret

        global af_signal_sighup
af_signal_sighup:
        mov     eax, SIGHUP
        ret
