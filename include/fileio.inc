; AsmFlow — file, descriptor, and process constants, in one place.
;
; These are kernel ABI numbers, not AsmFlow's. They were repeated at the top of
; each file that needed them, which was fine until two files needed the same
; name: NASM replaces a `%define` silently, so a duplicated name makes meaning
; depend on include order and nothing warns. `make check` rejects a name
; defined twice across `include/`, and this header is where the shared ones
; live so that rule has somewhere to point — the same arrangement
; `include/socket.inc` established for sockets.
;
; Values are x86-64 Linux.

%ifndef ASMFLOW_FILEIO_INC
%define ASMFLOW_FILEIO_INC

; --- open(2) ----------------------------------------------------------------
%define O_RDONLY   0
%define O_WRONLY   1
%define O_RDWR     2
%define O_NOFOLLOW 0x20000
%define O_NONBLOCK 0x800
%define O_CLOEXEC  0x80000

; --- fcntl(2) ---------------------------------------------------------------
%define F_GETFD    1
%define F_SETFD    2
%define F_GETFL    3
%define F_SETFL    4
%define FD_CLOEXEC 1

; --- pipe2(2) ---------------------------------------------------------------
; The two ends, by the index the kernel fills.
%define AF_PIPE_READ  0
%define AF_PIPE_WRITE 1

; --- wait4(2) ---------------------------------------------------------------
%define WNOHANG   1
%define WUNTRACED 2

; --- raw errno values used for process-race classification -----------------
%define AF_ERRNO_ESRCH  3
%define AF_ERRNO_EINTR  4
%define AF_ERRNO_ECHILD 10
%define AF_ERRNO_EACCES 13

; --- prctl(2) ---------------------------------------------------------------
; PR_SET_PDEATHSIG makes the kernel signal a child when the process that
; forked it dies. A supervisor that did not set it would leave its servers
; running after a crash, still holding whatever those servers hold.
%define PR_SET_PDEATHSIG 1

; --- signals ----------------------------------------------------------------
; The numbers and the mask operations, together, because anything that spawns a
; child needs both: a forked child inherits the daemon's blocked set, and a
; server started with SIGTERM blocked is a server that cannot be asked to stop.
%define SIG_BLOCK   0
%define SIG_UNBLOCK 1
%define SIG_SETMASK 2

%define SIGHUP   1
%define SIGINT   2
%define SIGQUIT  3
%define SIGKILL  9
%define SIGPIPE  13
%define SIGTERM  15
%define SIGCHLD  17

%endif ; ASMFLOW_FILEIO_INC
