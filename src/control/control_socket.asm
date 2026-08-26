; AsmFlow — control socket binding and permission policy.
;
; The control socket is the daemon's authority boundary. Anything that can write
; a frame to it can disable a provider, restart an MCP server, or trigger a tool
; call. It therefore lives at mode 0600 inside a 0700 directory, and both are
; verified rather than assumed (SECURITY_MODEL.md 13, HARNESS.md M4 DoD 5).
;
; Three details matter more than they look.
;
; The mode is set before the socket becomes reachable. bind(2) creates the node
; with the process umask applied, so a permissive umask would leave a window in
; which the socket exists and is world-writable. The umask is tightened around
; the bind and the mode is then set explicitly, so there is no window at all.
;
; A stale socket is removed only after it is proven dead. Unlinking whatever is
; at the path would let a second daemon silently steal a live socket from the
; first. A connect attempt distinguishes the two: ECONNREFUSED means nobody is
; listening and the node is stale; success means a daemon is already running and
; this one must refuse to start.
;
; The parent directory is created, not assumed. `${XDG_RUNTIME_DIR}/asmflow`
; usually does not exist on a fresh login.

        bits 64
        default rel

%include "asmflow.inc"
%include "control.inc"

        extern af_mem_zero
        extern af_mem_copy
        extern af_cstr_len
        extern af_sys_socket
        extern af_sys_bind
        extern af_sys_listen
        extern af_sys_connect
        extern af_sys_close
        extern af_sys_unlink
        extern af_sys_mkdir
        extern af_sys_chmod
        extern af_sys_umask
        extern af_sys_newfstatat
        extern af_sys_getuid
        extern af_status_from_errno

%define AF_UNIX        1
%define SOCK_STREAM    1
%define SOCK_NONBLOCK  0x800
%define SOCK_CLOEXEC   0x80000

; struct sockaddr_un { sa_family_t sun_family; char sun_path[108]; }
%define SUN_FAMILY 0
%define SUN_PATH   2
%define SUN_SIZE   110
%define SUN_PATH_MAX 108

; struct stat is large and layout-sensitive; only two fields are read from it.
%define STAT_SIZE     144
%define STAT_MODE_OFF 24
%define STAT_UID_OFF  28

%define S_IFMT   0o170000
%define S_IFSOCK 0o140000
%define S_IFDIR  0o040000
%define MODE_MASK 0o7777

%define AT_FDCWD (-100)
%define ECONNREFUSED 111
%define ENOENT       2
%define EEXIST       17

        section .text

; ---------------------------------------------------------------------------
; af_ctl_sockaddr(const char *path, void *out_sun) -> af_status
;
; Fills a sockaddr_un. AF_E_LIMIT when the path does not fit: sun_path is 108
; bytes and is NOT NUL-terminated by the kernel when full, so a path that
; exactly fills it would be ambiguous. One byte is reserved for the terminator.
; ---------------------------------------------------------------------------
        global af_ctl_sockaddr
af_ctl_sockaddr:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi                ; path
        mov     r12, rsi                ; sockaddr_un

        mov     rdi, r12
        mov     rsi, SUN_SIZE
        call    af_mem_zero

        mov     rdi, rbx
        call    af_cstr_len
        mov     r13, rax
        test    r13, r13
        jz      .invalid
        cmp     r13, SUN_PATH_MAX - 1
        ja      .too_long

        mov     word [r12 + SUN_FAMILY], AF_UNIX
        lea     rdi, [r12 + SUN_PATH]
        mov     rsi, rbx
        mov     rdx, r13
        call    af_mem_copy
        AF_LEAVE_OK
.too_long:
        AF_LEAVE_ERR AF_E_LIMIT
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_ctl_parent_dir(const char *path, char *out, u64 out_len) -> af_status
;
; Copies everything before the last '/'. AF_E_CFG_PATH for a path with no
; directory component, which cannot happen for a validated absolute path but is
; checked because this also runs on operator-supplied overrides.
; ---------------------------------------------------------------------------
        global af_ctl_parent_dir
af_ctl_parent_dir:
        AF_ENTER 16
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, rbx
        call    af_cstr_len
        mov     r14, rax
        test    r14, r14
        jz      .bad
.scan:
        test    r14, r14
        jz      .bad
        dec     r14
        cmp     byte [rbx + r14], '/'
        jne     .scan
        test    r14, r14
        jz      .root
        cmp     r14, r13
        jae     .too_long
        mov     rdi, r12
        mov     rsi, rbx
        mov     rdx, r14
        call    af_mem_copy
        mov     byte [r12 + r14], 0
        AF_LEAVE_OK
.root:
        ; The socket sits directly in "/", which the permission policy below
        ; would reject anyway; report it as a path error rather than trying to
        ; chmod the root directory.
        AF_LEAVE_ERR AF_E_CFG_PATH
.too_long:
        AF_LEAVE_ERR AF_E_LIMIT
.bad:
        AF_LEAVE_ERR AF_E_CFG_PATH

; ---------------------------------------------------------------------------
; af_ctl_ensure_dir(const char *dir) -> af_status
;
; Creates the directory at mode 0700 if it does not exist, and verifies the mode
; and owner if it does. An existing directory that is group- or world-accessible
; is refused rather than repaired: SECURITY_MODEL.md 13 forbids widening or
; narrowing permissions automatically, because either could be someone else's
; deliberate configuration.
; ---------------------------------------------------------------------------
        global af_ctl_ensure_dir
af_ctl_ensure_dir:
        AF_ENTER 192
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi

        mov     rdi, rbx
        mov     rsi, 0o700
        call    af_sys_mkdir
        test    rax, rax
        jns     .created
        neg     rax
        cmp     rax, EEXIST
        jne     .mkdir_failed

.created:
        ; Verify what is actually there, whether we made it or found it.
        mov     rdi, AT_FDCWD
        mov     rsi, rbx
        lea     rdx, [rsp]
        xor     ecx, ecx
        call    af_sys_newfstatat
        test    rax, rax
        js      .stat_failed

        mov     eax, [rsp + STAT_MODE_OFF]
        mov     ecx, eax
        and     ecx, S_IFMT
        cmp     ecx, S_IFDIR
        jne     .not_a_directory
        and     eax, MODE_MASK
        cmp     eax, 0o700
        jne     .bad_mode

        mov     r12d, [rsp + STAT_UID_OFF]
        call    af_sys_getuid
        cmp     eax, r12d
        jne     .bad_owner
        AF_LEAVE_OK

.mkdir_failed:
        neg     rax
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.stat_failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.not_a_directory:
        AF_LEAVE_ERR AF_E_CFG_PATH
.bad_mode:
        AF_LEAVE_ERR AF_E_PERM
.bad_owner:
        AF_LEAVE_ERR AF_E_PERM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_ctl_probe_stale(const char *path) -> af_status
;
; AF_E_NOTFOUND  nothing is at the path
; AF_OK          a socket is there but nobody is listening: safe to unlink
; AF_E_EXISTS    a daemon is already listening: this one must not start
; ---------------------------------------------------------------------------
        global af_ctl_probe_stale
af_ctl_probe_stale:
        AF_ENTER 320
        mov     rbx, rdi

        mov     rdi, AT_FDCWD
        mov     rsi, rbx
        lea     rdx, [rsp]
        xor     ecx, ecx
        call    af_sys_newfstatat
        test    rax, rax
        js      .stat_failed

        mov     eax, [rsp + STAT_MODE_OFF]
        and     eax, S_IFMT
        cmp     eax, S_IFSOCK
        jne     .not_a_socket

        ; Something is there. Ask whether it answers.
        mov     rdi, rbx
        lea     rsi, [rsp + 160]
        call    af_ctl_sockaddr
        test    rax, rax
        js      .done

        mov     edi, AF_UNIX
        mov     esi, SOCK_STREAM | SOCK_CLOEXEC
        xor     edx, edx
        call    af_sys_socket
        test    rax, rax
        js      .socket_failed
        mov     r12, rax

        mov     rdi, r12
        lea     rsi, [rsp + 160]
        mov     rdx, SUN_SIZE
        call    af_sys_connect
        mov     r13, rax
        mov     rdi, r12
        call    af_sys_close

        test    r13, r13
        jns     .live
        neg     r13
        cmp     r13, ECONNREFUSED
        je      .stale
        ; Anything else — a permission error, for instance — is not proof the
        ; node is dead, so it is not unlinked.
        mov     rdi, r13
        neg     rdi
        call    af_status_from_errno
        AF_LEAVE

.stale:
        AF_LEAVE_OK
.live:
        AF_LEAVE_ERR AF_E_EXISTS
.not_a_socket:
        ; A regular file at the socket path is somebody else's data.
        AF_LEAVE_ERR AF_E_CFG_PATH
.stat_failed:
        neg     rax
        cmp     rax, ENOENT
        je      .absent
        neg     rax
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.absent:
        AF_LEAVE_ERR AF_E_NOTFOUND
.socket_failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_bind(const char *path, i64 *out_fd) -> af_status
;
; Creates the directory, clears a proven-stale node, binds, sets the mode, and
; listens. On any failure nothing is left behind.
; ---------------------------------------------------------------------------
        global af_ctl_bind
af_ctl_bind:
        AF_ENTER 4352
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi                ; path
        mov     r12, rsi                ; out fd
        mov     qword [r12], -1

        ; [rsp + 0 .. 4096)   parent directory
        ; [rsp + 4096 .. 4206) sockaddr_un
        ; [rsp + 4208]        saved umask
        ; [rsp + 4216]        listening fd
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, 4096
        call    af_ctl_parent_dir
        test    rax, rax
        js      .done
        lea     rdi, [rsp]
        call    af_ctl_ensure_dir
        test    rax, rax
        js      .done

        mov     rdi, rbx
        call    af_ctl_probe_stale
        cmp     rax, AF_E_NOTFOUND
        je      .path_clear
        test    rax, rax
        js      .done                   ; live daemon, or an unexpected node
        mov     rdi, rbx
        call    af_sys_unlink
        test    rax, rax
        js      .unlink_failed
.path_clear:

        mov     rdi, rbx
        lea     rsi, [rsp + 4096]
        call    af_ctl_sockaddr
        test    rax, rax
        js      .done

        mov     edi, AF_UNIX
        mov     esi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
        xor     edx, edx
        call    af_sys_socket
        test    rax, rax
        js      .syscall_failed
        mov     [rsp + 4216], rax

        ; Tighten the umask across the bind so the node is never briefly
        ; reachable by anyone else, then restore it.
        mov     rdi, 0o177
        call    af_sys_umask
        mov     [rsp + 4208], rax

        mov     rdi, [rsp + 4216]
        lea     rsi, [rsp + 4096]
        mov     rdx, SUN_SIZE
        call    af_sys_bind
        mov     r13, rax

        mov     rdi, [rsp + 4208]
        call    af_sys_umask

        test    r13, r13
        js      .bind_failed

        ; Explicit mode as well as the umask: the umask only removes bits, and
        ; the contract is an exact 0600 rather than "no worse than".
        mov     rdi, rbx
        mov     rsi, 0o600
        call    af_sys_chmod
        test    rax, rax
        js      .chmod_failed

        mov     rdi, [rsp + 4216]
        mov     rsi, 64                 ; backlog
        call    af_sys_listen
        test    rax, rax
        js      .listen_failed

        mov     rax, [rsp + 4216]
        mov     [r12], rax
        AF_LEAVE_OK

.bind_failed:
        mov     rdi, [rsp + 4216]
        call    af_sys_close
        mov     rdi, r13
        call    af_status_from_errno
        AF_LEAVE
.chmod_failed:
.listen_failed:
        mov     [rsp + 4224], rax
        mov     rdi, [rsp + 4216]
        call    af_sys_close
        mov     rdi, rbx
        call    af_sys_unlink
        mov     rdi, [rsp + 4224]
        call    af_status_from_errno
        AF_LEAVE
.unlink_failed:
.syscall_failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_unbind(const char *path, i64 fd) -> void
;
; Closes the listener and removes the node. Called on shutdown, so it reports
; nothing: there is no longer anywhere to report to.
; ---------------------------------------------------------------------------
        global af_ctl_unbind
af_ctl_unbind:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        cmp     r12, 0
        jl      .no_fd
        mov     rdi, r12
        call    af_sys_close
.no_fd:
        test    rbx, rbx
        jz      .done
        mov     rdi, rbx
        call    af_sys_unlink
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_check_permissions(const char *path) -> af_status
;
; Verifies, after the fact, that the socket is a socket at exactly 0600 owned by
; this user, and that its parent is a directory at exactly 0700 owned by this
; user. HARNESS.md M4 DoD 5 asks for this as a test; having it as a function
; means the daemon can also assert it at startup rather than only in CI.
; ---------------------------------------------------------------------------
        global af_ctl_check_permissions
af_ctl_check_permissions:
        AF_ENTER 4352
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi

        mov     rdi, AT_FDCWD
        mov     rsi, rbx
        lea     rdx, [rsp + 4096]
        xor     ecx, ecx
        call    af_sys_newfstatat
        test    rax, rax
        js      .stat_failed

        mov     eax, [rsp + 4096 + STAT_MODE_OFF]
        mov     ecx, eax
        and     ecx, S_IFMT
        cmp     ecx, S_IFSOCK
        jne     .not_a_socket
        and     eax, MODE_MASK
        cmp     eax, 0o600
        jne     .bad_mode

        mov     r12d, [rsp + 4096 + STAT_UID_OFF]
        call    af_sys_getuid
        cmp     eax, r12d
        jne     .bad_owner

        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, 4096
        call    af_ctl_parent_dir
        test    rax, rax
        js      .done
        lea     rdi, [rsp]
        call    af_ctl_ensure_dir       ; re-verifies mode and owner
        AF_LEAVE

.not_a_socket:
        AF_LEAVE_ERR AF_E_CFG_PATH
.bad_mode:
.bad_owner:
        AF_LEAVE_ERR AF_E_PERM
.stat_failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE
