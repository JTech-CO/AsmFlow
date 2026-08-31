; AsmFlow — owner-only file and directory policy.
;
; Paths that contain configuration, the SQLite database, its WAL/SHM files,
; backups, or diagnostics are authority-bearing local state.  This module keeps
; the Linux stat policy in the platform layer so config and storage do not each
; grow subtly different copies of struct stat offsets and mode tests.
;
; All path pointers are BORROWED for the duration of the call.  The caller owns
; scratch buffers.  No function repairs an unsafe existing object: a surprising
; owner, type, symlink, or mode is rejected with AF_E_PERM/AF_E_CFG_PATH.

        bits 64
        default rel

%include "asmflow.inc"

        extern af_cstr_len
        extern af_mem_copy
        extern af_sys_mkdir
        extern af_sys_newfstatat
        extern af_sys_getuid
        extern af_status_from_errno

%define AF_PATH_MAX       4096
%define AT_FDCWD          (-100)
%define AT_SYMLINK_NOFOLLOW 0x100
%define ENOENT            2
%define EEXIST            17

; Linux x86-64 struct stat fields consumed here.
%define STAT_SIZE         144
%define STAT_MODE_OFF     24
%define STAT_UID_OFF      28

%define S_IFMT            0o170000
%define S_IFREG           0o100000
%define S_IFDIR           0o040000
%define MODE_MASK         0o7777
%define GROUP_WORLD_MASK  0o077

        section .text

; af_fs_parent_dir(const char *path, char *out, u64 out_cap) -> af_status
;
; `out` is caller-owned and receives a NUL-terminated absolute parent.  Paths
; directly below / are intentionally rejected: AsmFlow never creates or owns
; authority-bearing files in the filesystem root.
        global af_fs_parent_dir
af_fs_parent_dir:
        AF_ENTER 0
        test    rdi, rdi
        jz      .bad
        test    rsi, rsi
        jz      .bad
        test    rdx, rdx
        jz      .bad
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        mov     rdi, rbx
        call    af_cstr_len
        mov     r14, rax
        test    r14, r14
        jz      .bad
        cmp     r14, AF_PATH_MAX
        jae     .limit
.scan:
        test    r14, r14
        jz      .bad
        dec     r14
        cmp     byte [rbx + r14], '/'
        jne     .scan
        test    r14, r14
        jz      .bad
        cmp     r14, r13
        jae     .limit
        mov     rdi, r12
        mov     rsi, rbx
        mov     rdx, r14
        call    af_mem_copy
        mov     byte [r12 + r14], 0
        AF_LEAVE_OK
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.bad:
        AF_LEAVE_ERR AF_E_CFG_PATH

; af_fs_check_private_dir(const char *path) -> af_status
;
; Requires an actual (not symlink-followed) directory owned by this uid with
; exactly 0700 permissions.  Exact mode makes the state/runtime/config security
; boundary observable and deterministic instead of depending on ambient umask.
        global af_fs_check_private_dir
af_fs_check_private_dir:
        AF_ENTER 160
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, AT_FDCWD
        mov     rsi, rbx
        lea     rdx, [rsp]
        mov     rcx, AT_SYMLINK_NOFOLLOW
        call    af_sys_newfstatat
        test    rax, rax
        js      .stat_failed
        mov     eax, [rsp + STAT_MODE_OFF]
        mov     ecx, eax
        and     ecx, S_IFMT
        cmp     ecx, S_IFDIR
        jne     .wrong_type
        and     eax, MODE_MASK
        cmp     eax, 0o700
        jne     .bad_mode
        mov     r12d, [rsp + STAT_UID_OFF]
        call    af_sys_getuid
        cmp     eax, r12d
        jne     .bad_owner
        AF_LEAVE_OK
.stat_failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.wrong_type:
        AF_LEAVE_ERR AF_E_CFG_PATH
.bad_mode:
.bad_owner:
        AF_LEAVE_ERR AF_E_PERM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
; af_fs_ensure_private_dir(const char *path) -> af_status
;
; Creates a missing leaf at 0700.  EEXIST is not trusted; every path, including
; one just created, goes through the no-follow owner/type/mode verifier.
        global af_fs_ensure_private_dir
af_fs_ensure_private_dir:
        AF_ENTER 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, rbx
        mov     rsi, 0o700
        call    af_sys_mkdir
        test    rax, rax
        jns     .check
        neg     rax
        cmp     rax, EEXIST
        jne     .mkdir_failed
.check:
        mov     rdi, rbx
        call    af_fs_check_private_dir
        AF_LEAVE
.mkdir_failed:
        neg     rax
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_fs_check_private_file(const char *path, u64 require_write) -> af_status
;
; Accepts owner-readable 0400/0600-style regular files with no group/world
; permission bits.  `require_write != 0` additionally requires owner write;
; config can therefore be 0400 while the live SQLite database must be 0600.
        global af_fs_check_private_file
af_fs_check_private_file:
        AF_ENTER 160
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     rdi, AT_FDCWD
        mov     rsi, rbx
        lea     rdx, [rsp]
        mov     rcx, AT_SYMLINK_NOFOLLOW
        call    af_sys_newfstatat
        test    rax, rax
        js      .stat_failed
        mov     eax, [rsp + STAT_MODE_OFF]
        mov     ecx, eax
        and     ecx, S_IFMT
        cmp     ecx, S_IFREG
        jne     .wrong_type
        mov     ecx, eax
        and     ecx, GROUP_WORLD_MASK
        test    ecx, ecx
        jnz     .bad_mode
        test    eax, 0o400
        jz      .bad_mode
        test    r12, r12
        jz      .owner
        test    eax, 0o200
        jz      .bad_mode
.owner:
        mov     r12d, [rsp + STAT_UID_OFF]
        call    af_sys_getuid
        cmp     eax, r12d
        jne     .bad_owner
        AF_LEAVE_OK
.stat_failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.wrong_type:
        AF_LEAVE_ERR AF_E_CFG_PATH
.bad_mode:
.bad_owner:
        AF_LEAVE_ERR AF_E_PERM
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_fs_check_config_path(const char *path) -> af_status
;
; Uses a bounded stack scratch buffer.  Both the config and its immediate
; directory are checked without following a symlink.
        global af_fs_check_config_path
af_fs_check_config_path:
        AF_ENTER AF_PATH_MAX
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, AF_PATH_MAX
        call    af_fs_parent_dir
        test    rax, rax
        js      .done
        lea     rdi, [rsp]
        call    af_fs_check_private_dir
        test    rax, rax
        js      .done
        mov     rdi, rbx
        xor     esi, esi
        call    af_fs_check_private_file
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; af_fs_prepare_database_path(const char *path) -> af_status
;
; Ensures the state directory exists privately.  An existing database must
; already be a private owner-writable regular file; AF_E_NOTFOUND is the only
; case in which SQLite may create it under the daemon's 0077 umask.
        global af_fs_prepare_database_path
af_fs_prepare_database_path:
        AF_ENTER AF_PATH_MAX
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rdi, rbx
        lea     rsi, [rsp]
        mov     rdx, AF_PATH_MAX
        call    af_fs_parent_dir
        test    rax, rax
        js      .done
        lea     rdi, [rsp]
        call    af_fs_ensure_private_dir
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     esi, 1
        call    af_fs_check_private_file
        cmp     rax, AF_E_NOTFOUND
        jne     .done
        xor     eax, eax
.done:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
