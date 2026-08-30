; AsmFlow — spawning and reaping a supervised MCP server.
;
; `docs/SECURITY_MODEL.md` 11 and HARNESS.md M8 DoD 1 and 2 are the whole of
; the requirement: the child is executed, never interpreted, and it receives
; only the environment an operator named. There is no `system()`, no
; `/bin/sh -c`, and no string anywhere that a shell could re-parse — argv is a
; literal vector the configuration validated, so a server argument containing
; `; rm -rf /` is an argument containing those characters and nothing more.
;
; The window between fork and execve is the part worth reading carefully.
; Almost nothing is legal there: the child is a copy of a process that may have
; held any lock, so only async-signal-safe operations may run. Every syscall
; below that line is a raw syscall with no allocation and no libc, and
; everything the child needs — the argument vector, the environment block, the
; path — is built in the parent beforehand.
;
; Four things happen in that window and each is a supervision requirement
; rather than a nicety:
;
;   * the signal mask is restored to empty. A forked child inherits the
;     daemon's blocked set (ADR 0009 blocks everything and reads signalfd), and
;     a server started with SIGTERM blocked is a server that cannot be asked to
;     stop — it would have to be killed every time.
;   * PR_SET_PDEATHSIG makes the kernel signal the child if the daemon dies, so
;     a crash does not leave servers running with nobody supervising them.
;   * setpgid puts the child in its own process group, so terminating it
;     terminates whatever it spawned rather than orphaning grandchildren.
;   * the pipe ends are moved into place and the parent's copies are closed.
;     They were created with O_CLOEXEC, so anything not explicitly duplicated
;     is gone by the time the server's code runs.

        bits 64
        default rel

%include "asmflow.inc"
%include "errors.inc"
%include "fileio.inc"
%include "config.inc"
%include "mcp.inc"

        extern af_mem_zero
        extern af_cstr_len
        extern af_alloc
        extern af_free
        extern af_add_size
        extern af_add_size3
        extern af_mul_size
        extern af_cfg_getenv

        extern af_sys_fork
        extern af_sys_execve
        extern af_sys_pipe2
        extern af_sys_dup2
        extern af_sys_close
        extern af_sys_wait4
        extern af_sys_kill
        extern af_sys_setpgid
        extern af_sys_prctl
        extern af_sys_chdir
        extern af_sys_fcntl
        extern af_sys_rt_sigprocmask
        extern af_sys_getpid
        extern af_sys_getppid
        extern af_sys_exit_group
        extern af_status_from_errno

        section .text

; ---------------------------------------------------------------------------
; af_mcp_build_env(const af_cfg_mcp *cfg, char ***out_block) -> af_status
;
; The environment the child will receive: nothing but what the configuration
; named (M8 DoD 2).
;
; Two forms, both explicit. `env_allow` lists variables inherited from our own
; environment by name, and `env_pairs` maps a name the child will see onto a
; variable read from ours — which is how a secret reaches a server without ever
; appearing in the configuration file.
;
; The block is one allocation holding the pointer array and the "NAME=VALUE"
; strings after it, so releasing it is one af_free.
; ---------------------------------------------------------------------------
        global af_mcp_build_env
af_mcp_build_env:
        AF_ENTER 96
;   [rsp +  0]  cfg          [rsp + 32]  bytes needed
;   [rsp +  8]  out          [rsp + 40]  entries counted
;   [rsp + 16]  block        [rsp + 48]  write cursor
;   [rsp + 24]  strings      [rsp + 56]  loop index
        test    rsi, rsi
        jz      .invalid
        mov     qword [rsi], 0
        test    rdi, rdi
        jz      .invalid
        mov     [rsp], rdi
        mov     [rsp + 8], rsi
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 32], 0
        mov     qword [rsp + 40], 0
        mov     rbx, rdi

        ; --- first pass: how much room the block needs ---------------------
        xor     r12, r12
.count_allow:
        cmp     r12, [rbx + MCP_ENV_ALLOW_COUNT]
        jae     .count_pairs_start
        mov     rax, [rbx + MCP_ENV_ALLOW]
        mov     rdi, [rax + r12*8]
        test    rdi, rdi
        jz      .next_allow
        call    af_mcp_env_entry_size
        test    rax, rax
        js      .fail
        jz      .next_allow                     ; not set: not passed on
        cmp     rax, AF_MCP_ENV_ENTRY_MAX
        ja      .limit
        mov     rdi, [rsp + 32]
        mov     rsi, rax
        lea     rdx, [rsp + 32]
        call    af_add_size
        test    rax, rax
        js      .fail
        cmp     qword [rsp + 32], AF_MCP_ENV_BLOCK_MAX
        ja      .limit
        mov     rdi, [rsp + 40]
        mov     rsi, 1
        lea     rdx, [rsp + 40]
        call    af_add_size
        test    rax, rax
        js      .fail
.next_allow:
        inc     r12
        jmp     .count_allow

.count_pairs_start:
        xor     r12, r12
.count_pairs:
        cmp     r12, [rbx + MCP_ENV_PAIR_COUNT]
        jae     .counted
        mov     rax, r12
        imul    rax, rax, ENVP_SIZE
        add     rax, [rbx + MCP_ENV_PAIRS]
        mov     rdi, [rax + ENVP_NAME]
        mov     rsi, [rax + ENVP_ENV]
        call    af_mcp_pair_entry_size
        test    rax, rax
        js      .fail
        jz      .next_pair
        cmp     rax, AF_MCP_ENV_ENTRY_MAX
        ja      .limit
        mov     rdi, [rsp + 32]
        mov     rsi, rax
        lea     rdx, [rsp + 32]
        call    af_add_size
        test    rax, rax
        js      .fail
        cmp     qword [rsp + 32], AF_MCP_ENV_BLOCK_MAX
        ja      .limit
        mov     rdi, [rsp + 40]
        mov     rsi, 1
        lea     rdx, [rsp + 40]
        call    af_add_size
        test    rax, rax
        js      .fail
.next_pair:
        inc     r12
        jmp     .count_pairs

.counted:
        ; The pointer array is one entry longer than the count: execve wants a
        ; NULL terminator, and a block without one is a block the kernel walks
        ; off the end of.
        mov     rdi, [rsp + 40]
        mov     rsi, 1
        lea     rdx, [rsp + 64]
        call    af_add_size
        test    rax, rax
        js      .fail
        mov     rdi, [rsp + 64]
        mov     rsi, 8
        lea     rdx, [rsp + 72]
        call    af_mul_size
        test    rax, rax
        js      .fail
        mov     rdi, [rsp + 72]
        mov     rsi, [rsp + 32]
        lea     rdx, [rsp + 80]
        call    af_add_size
        test    rax, rax
        js      .fail
        cmp     qword [rsp + 80], AF_MCP_ENV_BLOCK_MAX
        ja      .limit
        mov     r13, [rsp + 72]                 ; array bytes
        mov     rdi, [rsp + 80]
        call    af_alloc
        test    rax, rax
        jz      .nomem
        mov     [rsp + 16], rax
        mov     r14, rax                        ; the pointer array
        lea     rax, [rax + r13]
        mov     [rsp + 24], rax                 ; where the strings begin
        mov     [rsp + 48], rax

        ; --- second pass: fill it ------------------------------------------
        xor     r15, r15                        ; entries written
        xor     r12, r12
.fill_allow:
        cmp     r12, [rbx + MCP_ENV_ALLOW_COUNT]
        jae     .fill_pairs_start
        mov     rax, [rbx + MCP_ENV_ALLOW]
        mov     rdi, [rax + r12*8]
        test    rdi, rdi
        jz      .next_fill_allow
        mov     rsi, rdi                        ; the same name on both sides
        mov     rdx, [rsp + 48]
        call    af_mcp_write_entry
        test    rax, rax
        jz      .next_fill_allow
        mov     rcx, [rsp + 48]
        mov     [r14 + r15*8], rcx
        inc     r15
        mov     rdi, rcx
        mov     rsi, rax
        lea     rdx, [rsp + 48]
        call    af_add_size
        test    rax, rax
        js      .owned_fail
.next_fill_allow:
        inc     r12
        jmp     .fill_allow

.fill_pairs_start:
        xor     r12, r12
.fill_pairs:
        cmp     r12, [rbx + MCP_ENV_PAIR_COUNT]
        jae     .filled
        mov     rax, r12
        imul    rax, rax, ENVP_SIZE
        add     rax, [rbx + MCP_ENV_PAIRS]
        mov     rdi, [rax + ENVP_NAME]
        mov     rsi, [rax + ENVP_ENV]
        mov     rdx, [rsp + 48]
        call    af_mcp_write_entry
        test    rax, rax
        jz      .next_fill_pair
        mov     rcx, [rsp + 48]
        mov     [r14 + r15*8], rcx
        inc     r15
        mov     rdi, rcx
        mov     rsi, rax
        lea     rdx, [rsp + 48]
        call    af_add_size
        test    rax, rax
        js      .owned_fail
.next_fill_pair:
        inc     r12
        jmp     .fill_pairs

.filled:
        mov     qword [r14 + r15*8], 0
        mov     rax, [rsp + 8]
        mov     rcx, [rsp + 16]
        mov     [rax], rcx
        AF_LEAVE_OK

.owned_fail:
        mov     [rsp + 88], rax
        mov     rdi, [rsp + 16]
        call    af_free
        mov     rax, [rsp + 88]
.fail:
        AF_LEAVE
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.limit:
        AF_LEAVE_ERR AF_E_LIMIT
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_env_entry_size(const char *name) -> i64
;
; How many bytes "NAME=VALUE\0" needs, or 0 when the variable is not set in our
; own environment, or a negative status on size overflow. An allowlisted name
; that is unset is simply not passed on: passing it empty would tell the child
; the operator set it to nothing, which is a different fact.
; ---------------------------------------------------------------------------
        global af_mcp_env_entry_size
af_mcp_env_entry_size:
        AF_ENTER 16
        test    rdi, rdi
        jz      .none
        mov     rbx, rdi
        call    af_cstr_len
        mov     r12, rax
        mov     rdi, rbx
        call    af_cfg_getenv
        test    rax, rax
        jz      .none
        mov     rdi, rax
        call    af_cstr_len
        mov     rdi, r12
        mov     rsi, rax
        mov     rdx, 2                          ; '=' and the NUL
        lea     rcx, [rsp]
        call    af_add_size3
        test    rax, rax
        js      .done
        mov     rax, [rsp]
.done:
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_pair_entry_size(const char *name, const char *source) -> i64
;   0 when source is unset, negative on size overflow.
; ---------------------------------------------------------------------------
        global af_mcp_pair_entry_size
af_mcp_pair_entry_size:
        AF_ENTER 16
        test    rdi, rdi
        jz      .none
        test    rsi, rsi
        jz      .none
        mov     rbx, rsi
        call    af_cstr_len
        mov     r12, rax
        mov     rdi, rbx
        call    af_cfg_getenv
        test    rax, rax
        jz      .none
        mov     rdi, rax
        call    af_cstr_len
        mov     rdi, r12
        mov     rsi, rax
        mov     rdx, 2
        lea     rcx, [rsp]
        call    af_add_size3
        test    rax, rax
        js      .done
        mov     rax, [rsp]
.done:
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_write_entry(const char *name, const char *source, char *dst) -> u64
;
; Writes "NAME=VALUE\0" at dst and answers how many bytes it used, or 0 when
; the source variable is unset.
; ---------------------------------------------------------------------------
        global af_mcp_write_entry
af_mcp_write_entry:
        AF_ENTER 48
        test    rdi, rdi
        jz      .none
        test    rsi, rsi
        jz      .none
        test    rdx, rdx
        jz      .none
        mov     rbx, rdi                        ; name
        mov     r12, rsi                        ; source variable
        mov     r13, rdx                        ; destination

        mov     rdi, r12
        call    af_cfg_getenv
        test    rax, rax
        jz      .none
        mov     r14, rax                        ; value

        xor     r15, r15
.copy_name:
        movzx   eax, byte [rbx + r15]
        test    al, al
        jz      .name_done
        mov     [r13 + r15], al
        inc     r15
        jmp     .copy_name
.name_done:
        mov     byte [r13 + r15], '='
        inc     r15

        xor     rcx, rcx
.copy_value:
        movzx   eax, byte [r14 + rcx]
        mov     [r13 + r15], al
        test    al, al
        jz      .value_done
        inc     r15
        inc     rcx
        jmp     .copy_value
.value_done:
        lea     rax, [r15 + 1]                  ; include the NUL
        AF_LEAVE
.none:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_build_argv(const af_cfg_mcp *cfg, char ***out) -> af_status
;
; argv[0] is the configured command and the rest are the configured arguments,
; verbatim. The array is one allocation of borrowed pointers into the snapshot:
; the strings outlive the spawn, and copying them would be copying the thing
; the configuration already owns.
; ---------------------------------------------------------------------------
        global af_mcp_build_argv
af_mcp_build_argv:
        AF_ENTER 48
        test    rsi, rsi
        jz      .invalid
        mov     qword [rsi], 0
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        cmp     qword [rbx + MCP_COMMAND], 0
        je      .invalid

        mov     rdi, [rbx + MCP_ARG_COUNT]
        mov     rsi, 2                          ; argv[0] and the NULL
        lea     rdx, [rsp]
        call    af_add_size
        test    rax, rax
        js      .done_status
        mov     rdi, [rsp]
        mov     rsi, 8
        lea     rdx, [rsp + 8]
        call    af_mul_size
        test    rax, rax
        js      .done_status
        mov     rdi, [rsp + 8]
        call    af_alloc
        test    rax, rax
        jz      .nomem
        mov     r13, rax

        mov     rcx, [rbx + MCP_COMMAND]
        mov     [r13], rcx
        xor     r14, r14
.copy:
        cmp     r14, [rbx + MCP_ARG_COUNT]
        jae     .done
        mov     rax, [rbx + MCP_ARGS]
        mov     rcx, [rax + r14*8]
        mov     [r13 + r14*8 + 8], rcx
        inc     r14
        jmp     .copy
.done:
        mov     qword [r13 + r14*8 + 8], 0
        mov     [r12], r13
        AF_LEAVE_OK
.nomem:
        AF_LEAVE_ERR AF_E_NOMEM
.done_status:
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_set_nonblock(int fd) -> raw syscall result
;
; Adds O_NONBLOCK without discarding any status flags already present. Kept
; private because callers outside this spawn path should use the platform I/O
; adapters rather than depending on raw fcntl results.
; ---------------------------------------------------------------------------
af_mcp_set_nonblock:
        AF_ENTER 0
        mov     rbx, rdi
        mov     rsi, F_GETFL
        xor     edx, edx
        call    af_sys_fcntl
        test    rax, rax
        js      .done
        mov     rdi, rbx
        mov     rsi, F_SETFL
        mov     rdx, rax
        or      rdx, O_NONBLOCK
        call    af_sys_fcntl
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_spawn(af_mcp_child *child) -> af_status
;
; Creates the three pipes, forks, and executes. On success the child's pid and
; our ends of its pipes are on the record; on failure nothing is left open and
; nothing is left running.
; ---------------------------------------------------------------------------
        global af_mcp_spawn
af_mcp_spawn:
        AF_ENTER 160
;   [rsp +  0]  stdin pipe pair    [rsp + 24]  argv
;   [rsp +  8]  stdout pipe pair   [rsp + 32]  envp
;   [rsp + 16] stderr pipe pair    [rsp + 40]  saved status
;   [rsp + 48] empty signal mask (8 bytes)
;   [rsp + 56] parent pid          [rsp + 64]  child pid
;   [rsp + 72] wait status
%define SP_IN   0
%define SP_OUT  8
%define SP_ERR  16
%define SP_ARGV 24
%define SP_ENVP 32
%define SP_ERRC 40
%define SP_MASK 48
%define SP_PARENT_PID 56
%define SP_CHILD_PID  64
%define SP_WAIT_STATUS 72
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, [rbx + MC_CFG]
        test    r12, r12
        jz      .invalid
        mov     qword [rsp + SP_ARGV], 0
        mov     qword [rsp + SP_ENVP], 0
        mov     dword [rsp + SP_IN], -1
        mov     dword [rsp + SP_IN + 4], -1
        mov     dword [rsp + SP_OUT], -1
        mov     dword [rsp + SP_OUT + 4], -1
        mov     dword [rsp + SP_ERR], -1
        mov     dword [rsp + SP_ERR + 4], -1

        mov     rdi, r12
        lea     rsi, [rsp + SP_ARGV]
        call    af_mcp_build_argv
        test    rax, rax
        js      .fail
        mov     rdi, r12
        lea     rsi, [rsp + SP_ENVP]
        call    af_mcp_build_env
        test    rax, rax
        js      .fail

        ; Every pipe is created close-on-exec. Only the ends retained by the
        ; parent become non-blocking; the child's stdin/stdout/stderr stay
        ; blocking, as ordinary stdio programs expect.
        lea     rdi, [rsp + SP_IN]
        mov     rsi, O_CLOEXEC
        call    af_sys_pipe2
        test    rax, rax
        js      .syscall_failed
        lea     rdi, [rsp + SP_OUT]
        mov     rsi, O_CLOEXEC
        call    af_sys_pipe2
        test    rax, rax
        js      .syscall_failed
        lea     rdi, [rsp + SP_ERR]
        mov     rsi, O_CLOEXEC
        call    af_sys_pipe2
        test    rax, rax
        js      .syscall_failed

        movsxd  rdi, dword [rsp + SP_IN + 4]
        call    af_mcp_set_nonblock
        test    rax, rax
        js      .syscall_failed
        movsxd  rdi, dword [rsp + SP_OUT + 0]
        call    af_mcp_set_nonblock
        test    rax, rax
        js      .syscall_failed
        movsxd  rdi, dword [rsp + SP_ERR + 0]
        call    af_mcp_set_nonblock
        test    rax, rax
        js      .syscall_failed

        call    af_sys_getpid
        test    rax, rax
        js      .syscall_failed
        mov     [rsp + SP_PARENT_PID], rax

        call    af_sys_fork
        test    rax, rax
        js      .syscall_failed
        test    rax, rax
        jz      .child
        mov     [rsp + SP_CHILD_PID], rax

        ; The child performs the authoritative setpgid before exec. The parent
        ; repeats it to close the race with an immediate signal. EACCES means
        ; the child won the race and execed; ESRCH means it already exited.
        mov     rdi, rax
        mov     rsi, rax
        call    af_sys_setpgid
        test    rax, rax
        jns     .parent_group_ready
        cmp     rax, -AF_ERRNO_EACCES
        je      .parent_group_ready
        cmp     rax, -AF_ERRNO_ESRCH
        je      .parent_group_ready
        jmp     .parent_group_failed

.parent_group_ready:
        mov     rax, [rsp + SP_CHILD_PID]
        mov     [rbx + MC_PID], rax
        mov     [rbx + MC_PGID], rax

        ; --- parent ---------------------------------------------------------
        ; The ends that belong to the child are closed here. A parent holding
        ; the write end of the child's stdout would never see EOF when the
        ; child exits, and the supervisor would wait forever for a process that
        ; had already gone.
        movsxd  rdi, dword [rsp + SP_IN + 0]
        call    af_sys_close
        movsxd  rdi, dword [rsp + SP_OUT + 4]
        call    af_sys_close
        movsxd  rdi, dword [rsp + SP_ERR + 4]
        call    af_sys_close

        movsxd  rax, dword [rsp + SP_IN + 4]
        mov     [rbx + MC_STDIN_FD], rax
        movsxd  rax, dword [rsp + SP_OUT + 0]
        mov     [rbx + MC_STDOUT_FD], rax
        movsxd  rax, dword [rsp + SP_ERR + 0]
        mov     [rbx + MC_STDERR_FD], rax
        or      qword [rbx + MC_FLAGS], AF_MC_F_STDIN_OPEN
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_REAPED
        inc     qword [rbx + MC_STARTS]

        mov     rdi, [rsp + SP_ARGV]
        call    af_free
        mov     rdi, [rsp + SP_ENVP]
        call    af_free
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; --- child ------------------------------------------------------------------
; Everything from here runs in a copy of a process that may have held any lock.
; Only raw syscalls are legal, and every one of them is one the child must make
; before it stops being AsmFlow.
; ---------------------------------------------------------------------------
.child:
        ; The daemon reads its signals from a descriptor and therefore blocks
        ; them all (ADR 0009). A child that inherited that mask could not be
        ; asked to stop with SIGTERM, only killed.
        mov     qword [rsp + SP_MASK], 0
        mov     rdi, SIG_SETMASK
        lea     rsi, [rsp + SP_MASK]
        xor     edx, edx
        mov     rcx, 8
        call    af_sys_rt_sigprocmask
        test    rax, rax
        js      .child_failed

        ; If the daemon dies, so does this. Otherwise a crash leaves servers
        ; running with nobody supervising them and nobody to reap them.
        mov     rdi, PR_SET_PDEATHSIG
        mov     rsi, SIGKILL
        xor     edx, edx
        xor     ecx, ecx
        xor     r8, r8
        call    af_sys_prctl
        test    rax, rax
        js      .child_failed

        ; PR_SET_PDEATHSIG is not retroactive. If the daemon died between fork
        ; and prctl, getppid no longer matches the pid captured before fork.
        call    af_sys_getppid
        test    rax, rax
        js      .child_failed
        cmp     rax, [rsp + SP_PARENT_PID]
        jne     .child_failed

        ; Its own process group, so stopping it stops what it started.
        xor     edi, edi
        xor     esi, esi
        call    af_sys_setpgid
        test    rax, rax
        js      .child_failed

        movsxd  rdi, dword [rsp + SP_IN + 0]
        xor     esi, esi                        ; stdin
        call    af_sys_dup2
        test    rax, rax
        js      .child_failed
        movsxd  rdi, dword [rsp + SP_OUT + 4]
        mov     rsi, 1                          ; stdout
        call    af_sys_dup2
        test    rax, rax
        js      .child_failed
        movsxd  rdi, dword [rsp + SP_ERR + 4]
        mov     rsi, 2                          ; stderr
        call    af_sys_dup2
        test    rax, rax
        js      .child_failed

        ; dup2 clears FD_CLOEXEC only when oldfd differs from newfd. Clear it
        ; explicitly so descriptor-number reuse cannot close a stdio target at
        ; execve.
        xor     edi, edi                        ; stdin
        mov     rsi, F_SETFD
        xor     edx, edx
        call    af_sys_fcntl
        test    rax, rax
        js      .child_failed
        mov     rdi, 1                          ; stdout
        mov     rsi, F_SETFD
        xor     edx, edx
        call    af_sys_fcntl
        test    rax, rax
        js      .child_failed
        mov     rdi, 2                          ; stderr
        mov     rsi, F_SETFD
        xor     edx, edx
        call    af_sys_fcntl
        test    rax, rax
        js      .child_failed

        mov     rdi, [rbx + MC_CFG]
        mov     rdi, [rdi + MCP_CWD]
        test    rdi, rdi
        jz      .no_cwd
        call    af_sys_chdir
        test    rax, rax
        js      .child_failed
.no_cwd:

        ; No shell, no interpretation: the command and its arguments as the
        ; configuration wrote them (M8 DoD 1).
        mov     rdi, [rbx + MC_CFG]
        mov     rdi, [rdi + MCP_COMMAND]
        mov     rsi, [rsp + SP_ARGV]
        mov     rdx, [rsp + SP_ENVP]
        call    af_sys_execve

.child_failed:
        ; execve returned, so it failed. This process is a copy of the daemon
        ; and must not run any of it: exit immediately with a status the parent
        ; can recognise.
        mov     rdi, AF_MCP_EXEC_FAILED
        call    af_sys_exit_group
        ud2

.parent_group_failed:
        ; A failure other than the documented exec/exit races leaves grouping
        ; uncertain. Kill the direct child and reap it before returning so the
        ; caller never inherits a live, unsupervised process.
        mov     rdi, rax
        call    af_status_from_errno
        mov     [rsp + SP_ERRC], rax
        mov     rdi, [rsp + SP_CHILD_PID]
        mov     rsi, SIGKILL
        call    af_sys_kill
.reap_failed_child:
        mov     rdi, [rsp + SP_CHILD_PID]
        lea     rsi, [rsp + SP_WAIT_STATUS]
        xor     edx, edx
        xor     ecx, ecx
        call    af_sys_wait4
        cmp     rax, -AF_ERRNO_EINTR
        je      .reap_failed_child
        jmp     .cleanup_local_fds

.syscall_failed:
        mov     rdi, rax
        call    af_status_from_errno
.fail:
        mov     [rsp + SP_ERRC], rax
.cleanup_local_fds:
        ; Before MC_* owns any descriptor, every pipe end is local state. Close
        ; all six on every setup/fork failure, including partially built pipes.
        xor     r13d, r13d
.close_local_fd:
        cmp     r13d, 24
        jae     .free_spawn_blocks
        movsxd  rdi, dword [rsp + r13]
        cmp     edi, 0
        jl      .next_local_fd
        call    af_sys_close
        mov     dword [rsp + r13], -1
.next_local_fd:
        add     r13, 4
        jmp     .close_local_fd
.free_spawn_blocks:
        mov     rdi, [rsp + SP_ARGV]
        call    af_free
        mov     rdi, [rsp + SP_ENVP]
        call    af_free
        mov     rax, [rsp + SP_ERRC]
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_close_pipes(af_mcp_child *child) -> void
;
; Closes whichever of our three ends are open and marks them so. Idempotent,
; because a shutdown path may reach it twice and a descriptor closed twice is a
; descriptor that could already belong to something else.
; ---------------------------------------------------------------------------
        global af_mcp_close_pipes
af_mcp_close_pipes:
        AF_ENTER 16
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi

        mov     rdi, [rbx + MC_STDIN_FD]
        cmp     rdi, 0
        jl      .no_stdin
        call    af_sys_close
        mov     qword [rbx + MC_STDIN_FD], -1
.no_stdin:
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_STDIN_OPEN

        mov     rdi, [rbx + MC_STDOUT_FD]
        cmp     rdi, 0
        jl      .no_stdout
        call    af_sys_close
        mov     qword [rbx + MC_STDOUT_FD], -1
.no_stdout:
        mov     rdi, [rbx + MC_STDERR_FD]
        cmp     rdi, 0
        jl      .done
        call    af_sys_close
        mov     qword [rbx + MC_STDERR_FD], -1
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_close_stdin(af_mcp_child *child) -> void
;
; Step three of the shutdown sequence (docs/MCP_COMPATIBILITY.md 10). A server
; that reads until EOF stops on its own, which is the polite ending; the signal
; that follows is for the ones that do not.
; ---------------------------------------------------------------------------
        global af_mcp_close_stdin
af_mcp_close_stdin:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rdi, [rbx + MC_STDIN_FD]
        cmp     rdi, 0
        jl      .done
        call    af_sys_close
        mov     qword [rbx + MC_STDIN_FD], -1
        and     qword [rbx + MC_FLAGS], ~AF_MC_F_STDIN_OPEN
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_mcp_signal(af_mcp_child *child, i64 signal) -> af_status
;
; Signals the child's whole process group. MC_PGID deliberately outlives
; MC_PID: wait4 may collect a leader while its same-group helpers remain.
; ESRCH is success for teardown because it proves that saved group is already
; gone; any other syscall failure leaves the PGID owned for a later retry.
; ---------------------------------------------------------------------------
        global af_mcp_signal
af_mcp_signal:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     rax, [rbx + MC_PGID]
        cmp     rax, 0
        jle     .no_child
        neg     rax                             ; negative pid: the group
        mov     rdi, rax
        mov     rsi, r12
        call    af_sys_kill
        test    rax, rax
        js      .syscall_failed
        AF_LEAVE_OK
.no_child:
        AF_LEAVE_ERR AF_E_NOTFOUND
.syscall_failed:
        cmp     rax, -AF_ERRNO_ESRCH
        je      .already_gone
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.already_gone:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_reap(af_mcp_child *child) -> i64
;
; 1 when the child was collected, 0 when it is still running, negative on a
; failure that is not "no such child".
;
; This is what makes M8 DoD 8 true: every path that ends a child ends here, and
; a process nobody waits for is a zombie regardless of how it was stopped.
; ---------------------------------------------------------------------------
        global af_mcp_reap
af_mcp_reap:
        AF_ENTER 48
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     rax, [rbx + MC_PID]
        cmp     rax, 0
        jle     .not_running

        mov     dword [rsp], 0
        mov     rdi, [rbx + MC_PID]
        lea     rsi, [rsp]
        mov     rdx, WNOHANG
        xor     ecx, ecx
        call    af_sys_wait4
        cmp     rax, 0
        jl      .wait_failed
        test    rax, rax
        jz      .still_running

        ; Collected. The exit status is recorded in the shape wait4 returned it
        ; so that "exited 3" and "killed by 9" stay distinguishable. Only the
        ; direct PID is retired here: MC_PGID remains owned until teardown has
        ; delivered SIGKILL to any surviving helpers (or observed ESRCH).
        mov     eax, dword [rsp]
        mov     [rbx + MC_LAST_EXIT], rax
        mov     rcx, rax
        and     rcx, 0x7f
        mov     [rbx + MC_LAST_SIGNAL], rcx
        inc     qword [rbx + MC_EXITS]
        mov     qword [rbx + MC_PID], 0
        or      qword [rbx + MC_FLAGS], AF_MC_F_REAPED
        mov     eax, 1
        AF_LEAVE

.still_running:
        xor     eax, eax
        AF_LEAVE
.not_running:
        xor     eax, eax
        AF_LEAVE
.wait_failed:
        ; ECHILD means somebody already collected it, which is not a failure to
        ; report: the outcome the caller wanted has happened.
        cmp     rax, -AF_ERRNO_ECHILD
        je      .gone
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.gone:
        mov     qword [rbx + MC_PID], 0
        or      qword [rbx + MC_FLAGS], AF_MC_F_REAPED
        mov     eax, 1
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_mcp_exit_code(const af_mcp_child *child) -> i64
;
; The exit status as a number an operator can read: 0-255 for a normal exit,
; and 128 plus the signal number for one that was killed. Derived rather than
; stored, so the raw wait status stays available for anything that needs it.
; ---------------------------------------------------------------------------
        global af_mcp_exit_code
af_mcp_exit_code:
        test    rdi, rdi
        jz      .zero
        mov     rax, [rdi + MC_LAST_EXIT]
        mov     rcx, rax
        and     rcx, 0x7f
        test    rcx, rcx
        jnz     .signalled
        shr     rax, 8
        and     rax, 0xff
        ret
.signalled:
        lea     rax, [rcx + 128]
        ret
.zero:
        xor     eax, eax
        ret
