; AsmFlow — Linux x86-64 raw syscall adapters.
;
; These are the only place in the runtime that issues `syscall`. Everything
; above this file works in terms of af_status codes and never inspects errno
; directly.
;
; Return convention
; -----------------
; The kernel returns a negative errno in rax on failure. These wrappers pass
; that through unchanged: callers get `>= 0` on success and `-errno` on
; failure, and convert to an AF_E_* code with af_status_from_errno.
;
; Ownership: every pointer argument is BORROWED for the duration of the call.
;
; These are leaf functions. They issue no `call`, so the uniform AF_ENTER frame
; is unnecessary; rcx and r11 are clobbered by `syscall` itself and are
; caller-saved under the System V AMD64 ABI, so no callee-saved register is
; ever touched here.

        bits 64
        default rel

%include "asmflow.inc"

%define SYS_read            0
%define SYS_write           1
%define SYS_open            2
%define SYS_close           3
%define SYS_fstat           5
%define SYS_lseek           8
%define SYS_mmap            9
%define SYS_mprotect        10
%define SYS_munmap          11
%define SYS_rt_sigaction    13
%define SYS_rt_sigprocmask  14
%define SYS_ioctl           16
%define SYS_pipe            22
%define SYS_dup             32
%define SYS_dup2            33
%define SYS_nanosleep       35
%define SYS_getpid          39
%define SYS_socket          41
%define SYS_connect         42
%define SYS_accept          43
%define SYS_sendto          44
%define SYS_recvfrom        45
%define SYS_shutdown        48
%define SYS_bind            49
%define SYS_listen          50
%define SYS_setsockopt      54
%define SYS_getsockopt      55
%define SYS_clone           56
%define SYS_fork            57
%define SYS_execve          59
%define SYS_exit            60
%define SYS_wait4           61
%define SYS_kill            62
%define SYS_uname           63
%define SYS_fcntl           72
%define SYS_fsync           74
%define SYS_ftruncate       77
%define SYS_getcwd          79
%define SYS_chdir           80
%define SYS_rename          82
%define SYS_mkdir           83
%define SYS_rmdir           84
%define SYS_unlink          87
%define SYS_readlink        89
%define SYS_chmod           90
%define SYS_fchmod          91
%define SYS_umask           95
%define SYS_getuid          102
%define SYS_getgid          104
%define SYS_geteuid         107
%define SYS_getegid         108
%define SYS_setpgid         109
%define SYS_getppid         110
%define SYS_setsid          112
%define SYS_sigaltstack     131
%define SYS_statfs          137
%define SYS_prctl           157
%define SYS_gettid          186
%define SYS_futex           202
%define SYS_clock_gettime   228
%define SYS_exit_group      231
%define SYS_epoll_wait      232
%define SYS_epoll_ctl       233
%define SYS_openat          257
%define SYS_mkdirat         258
%define SYS_newfstatat      262
%define SYS_unlinkat        263
%define SYS_accept4         288
%define SYS_eventfd2        290
%define SYS_epoll_create1   291
%define SYS_pipe2           293
%define SYS_prlimit64       302
%define SYS_getrandom       318
%define SYS_signalfd4       289
%define SYS_timerfd_create  283
%define SYS_timerfd_settime 286

; ---------------------------------------------------------------------------
; Small syscall trampolines.
;
; AF_SYSCALL name, number, argcount
;   Emits `af_sys_<name>` taking the syscall's arguments in the C order. The
;   kernel takes its 4th argument in r10 rather than rcx, which is the only
;   place the two conventions differ for these calls.
; ---------------------------------------------------------------------------
%macro AF_SYSCALL 3
        global af_sys_%1
af_sys_%1:
    %if (%3) >= 4
        mov     r10, rcx
    %endif
        mov     eax, %2
        syscall
        ret
%endmacro

        section .text

AF_SYSCALL read,           SYS_read,           3
AF_SYSCALL write,          SYS_write,          3
AF_SYSCALL close,          SYS_close,          1
AF_SYSCALL fstat,          SYS_fstat,          2
AF_SYSCALL lseek,          SYS_lseek,          3
AF_SYSCALL mmap,           SYS_mmap,           6
AF_SYSCALL mprotect,       SYS_mprotect,       3
AF_SYSCALL munmap,         SYS_munmap,         2
AF_SYSCALL rt_sigaction,   SYS_rt_sigaction,   4
AF_SYSCALL rt_sigprocmask, SYS_rt_sigprocmask, 4
AF_SYSCALL ioctl,          SYS_ioctl,          3
AF_SYSCALL dup,            SYS_dup,            1
AF_SYSCALL dup2,           SYS_dup2,           2
AF_SYSCALL nanosleep,      SYS_nanosleep,      2
AF_SYSCALL getpid,         SYS_getpid,         0
AF_SYSCALL getppid,        SYS_getppid,        0
AF_SYSCALL socket,         SYS_socket,         3
AF_SYSCALL connect,        SYS_connect,        3
AF_SYSCALL sendto,         SYS_sendto,         6
AF_SYSCALL recvfrom,       SYS_recvfrom,       6
AF_SYSCALL shutdown,       SYS_shutdown,       2
AF_SYSCALL bind,           SYS_bind,           3
AF_SYSCALL listen,         SYS_listen,         2
AF_SYSCALL setsockopt,     SYS_setsockopt,     5
AF_SYSCALL getsockopt,     SYS_getsockopt,     5
AF_SYSCALL fork,           SYS_fork,           0
AF_SYSCALL execve,         SYS_execve,         3
AF_SYSCALL wait4,          SYS_wait4,          4
AF_SYSCALL kill,           SYS_kill,           2
AF_SYSCALL fcntl,          SYS_fcntl,          3
AF_SYSCALL fsync,          SYS_fsync,          1
AF_SYSCALL getcwd,         SYS_getcwd,         2
AF_SYSCALL chdir,          SYS_chdir,          1
AF_SYSCALL rename,         SYS_rename,         2
AF_SYSCALL mkdir,          SYS_mkdir,          2
AF_SYSCALL rmdir,          SYS_rmdir,          1
AF_SYSCALL unlink,         SYS_unlink,         1
AF_SYSCALL readlink,       SYS_readlink,       3
AF_SYSCALL chmod,          SYS_chmod,          2
AF_SYSCALL fchmod,         SYS_fchmod,         2
AF_SYSCALL umask,          SYS_umask,          1
AF_SYSCALL getuid,         SYS_getuid,         0
AF_SYSCALL geteuid,        SYS_geteuid,        0
AF_SYSCALL getgid,         SYS_getgid,         0
AF_SYSCALL setpgid,        SYS_setpgid,        2
AF_SYSCALL setsid,         SYS_setsid,         0
AF_SYSCALL prctl,          SYS_prctl,          5
AF_SYSCALL clock_gettime,  SYS_clock_gettime,  2
AF_SYSCALL epoll_wait,     SYS_epoll_wait,     4
AF_SYSCALL epoll_ctl,      SYS_epoll_ctl,      4
AF_SYSCALL openat,         SYS_openat,         4
AF_SYSCALL newfstatat,     SYS_newfstatat,     4
AF_SYSCALL accept4,        SYS_accept4,        4
AF_SYSCALL eventfd2,       SYS_eventfd2,       2
AF_SYSCALL epoll_create1,  SYS_epoll_create1,  1
AF_SYSCALL pipe2,          SYS_pipe2,          2
AF_SYSCALL prlimit64,      SYS_prlimit64,      4
AF_SYSCALL getrandom,      SYS_getrandom,      3
AF_SYSCALL signalfd4,      SYS_signalfd4,      4
AF_SYSCALL timerfd_create, SYS_timerfd_create, 2
AF_SYSCALL timerfd_settime, SYS_timerfd_settime, 4

; ---------------------------------------------------------------------------
; af_sys_open(const char *path, int flags, mode_t mode) -> i64
;
; Routed through openat(AT_FDCWD) because the bare open syscall is absent on
; some architectures and openat is the form the rest of the platform layer
; already uses.
; ---------------------------------------------------------------------------
        global af_sys_open
af_sys_open:
        mov     rcx, rdx                ; mode
        mov     rdx, rsi                ; flags
        mov     rsi, rdi                ; path
        mov     rdi, -100               ; AT_FDCWD
        mov     r10, rcx
        mov     eax, SYS_openat
        syscall
        ret

; ---------------------------------------------------------------------------
; af_sys_exit_group(int status) -> does not return
; ---------------------------------------------------------------------------
        global af_sys_exit_group
af_sys_exit_group:
        mov     eax, SYS_exit_group
        syscall
        ud2                             ; unreachable; trap if the kernel returns

; ---------------------------------------------------------------------------
; af_status_from_errno(i64 raw) -> af_status
;
; Maps a raw syscall return value onto the af_status contract. Non-negative
; input is AF_OK; the mapped codes below are the ones callers act on
; differently from a generic system error.
; ---------------------------------------------------------------------------
%define E_INTR      4
%define E_AGAIN     11
%define E_NOMEM     12
%define E_ACCES     13
%define E_EXIST     17
%define E_INVAL     22
%define E_NFILE     23
%define E_MFILE     24
%define E_PIPE      32
%define E_NAMETOOLONG 36
%define E_NOENT     2
%define E_PERM      1
%define E_TIMEDOUT  110
%define E_CONNRESET 104

        global af_status_from_errno
af_status_from_errno:
        test    rdi, rdi
        jns     .ok
        neg     rdi                     ; rdi = errno
        cmp     rdi, E_INTR
        je      .intr
        cmp     rdi, E_AGAIN
        je      .again
        cmp     rdi, E_NOMEM
        je      .nomem
        cmp     rdi, E_ACCES
        je      .perm
        cmp     rdi, E_PERM
        je      .perm
        cmp     rdi, E_EXIST
        je      .exists
        cmp     rdi, E_NOENT
        je      .notfound
        cmp     rdi, E_INVAL
        je      .invalid
        cmp     rdi, E_PIPE
        je      .pipe
        cmp     rdi, E_TIMEDOUT
        je      .timeout
        cmp     rdi, E_CONNRESET
        je      .eof
        mov     rax, AF_E_SYS
        ret
.ok:
        xor     eax, eax
        ret
.intr:
        mov     rax, AF_E_INTR
        ret
.again:
        mov     rax, AF_E_AGAIN
        ret
.nomem:
        mov     rax, AF_E_NOMEM
        ret
.perm:
        mov     rax, AF_E_PERM
        ret
.exists:
        mov     rax, AF_E_EXISTS
        ret
.notfound:
        mov     rax, AF_E_NOTFOUND
        ret
.invalid:
        mov     rax, AF_E_INVALID
        ret
.pipe:
        mov     rax, AF_E_PIPE
        ret
.timeout:
        mov     rax, AF_E_TIMEOUT
        ret
.eof:
        mov     rax, AF_E_EOF
        ret

; ---------------------------------------------------------------------------
; af_write_all(int fd, const void *buf, size_t len) -> af_status
;
; Retries short writes and EINTR. Ownership: `buf` is BORROWED.
; ---------------------------------------------------------------------------
        global af_write_all
af_write_all:
        AF_ENTER 0
        mov     rbx, rdi                ; fd
        mov     r12, rsi                ; cursor
        mov     r13, rdx                ; remaining
.loop:
        test    r13, r13
        jz      .done
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        call    af_sys_write
        test    rax, rax
        js      .err
        jz      .short                  ; write(2) returning 0 makes no progress
        add     r12, rax
        sub     r13, rax
        jmp     .loop
.done:
        AF_LEAVE_OK
.short:
        AF_LEAVE_ERR AF_E_PIPE
.err:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_INTR
        je      .loop
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_read_some(int fd, void *buf, size_t len, i64 *out_n) -> af_status
;
; One read, retrying only EINTR. AF_E_EOF when the peer closed. Ownership:
; `buf` and `out_n` are BORROWED and written only on success.
; ---------------------------------------------------------------------------
        global af_read_some
af_read_some:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     r14, rcx
.loop:
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        call    af_sys_read
        test    rax, rax
        js      .err
        jz      .eof
        mov     [r14], rax
        AF_LEAVE_OK
.eof:
        AF_LEAVE_ERR AF_E_EOF
.err:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_INTR
        je      .loop
        AF_LEAVE
