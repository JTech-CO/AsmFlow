; AsmFlow — control-socket server.
;
; Accepts local clients, frames NDJSON in both directions, and hands each
; complete request to the dispatcher. Everything runs inside the single event
; loop: no thread is created, and every callback runs to completion.
;
; Three behaviours are load-bearing.
;
; Slots are bounded and reclaimed. A connection table with a fixed size means a
; client that opens sockets in a loop is refused rather than allowed to exhaust
; the process's descriptors, and every close path — orderly, error, and
; peer-reset — runs through one release function. HARNESS.md M4 DoD 7 asks for
; zero descriptor leak after a hundred connect/disconnect cycles, and one
; release path is how that is arranged rather than hoped for.
;
; A protocol error ends the connection. An oversized or non-UTF-8 frame leaves
; the framer unable to tell where the next message starts, so the server sends
; one final error and closes instead of trying to resynchronise.
;
; Writes are drained, not assumed. A response larger than the socket buffer is
; kept in the outbox and EPOLLOUT is enabled until it is gone, so a client that
; stops reading blocks itself rather than the daemon.

        bits 64
        default rel

%include "asmflow.inc"
%include "control.inc"
%include "loop.inc"
%include "runtime.inc"

        extern af_mem_zero
        extern af_buf_init
        extern af_buf_free
        extern af_buf_clear
        extern af_buf_data
        extern af_buf_len
        extern af_buf_reserve
        extern af_buf_consume

        extern af_ctl_bind
        extern af_ctl_unbind
        extern af_ctl_frame_next
        extern af_ctl_frame_consume
        extern af_ctl_dispatch_frame
        extern af_ctl_write_protocol_error

        extern af_loop_add
        extern af_loop_mod
        extern af_loop_del

        extern af_sys_accept4
        extern af_sys_close
        extern af_sys_read
        extern af_sys_write
        extern af_sys_getsockopt
        extern af_status_from_errno

%define SOCK_NONBLOCK 0x800
%define SOCK_CLOEXEC  0x80000
%define SOL_SOCKET    1
%define SO_PEERCRED   17

%define AF_CTL_READ_CHUNK 65536

        section .text

; ---------------------------------------------------------------------------
; af_ctl_server_init(af_ctl_server *s, const char *path, u64 frame_max,
;                    af_loop *loop, void *rt) -> af_status
;
; Ownership: `path`, `loop`, and `rt` are BORROWED and must outlive the server.
; ---------------------------------------------------------------------------
        global af_ctl_server_init
af_ctl_server_init:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rcx, rcx
        jz      .invalid
        mov     rbx, rdi                ; server
        mov     r12, rsi                ; path
        mov     r13, rdx                ; frame ceiling
        mov     r14, rcx                ; loop
        mov     r15, r8                 ; runtime

        mov     rdi, rbx
        mov     rsi, CTLS_SIZE
        call    af_mem_zero
        mov     qword [rbx + CTLS_LISTEN_FD], -1
        mov     [rbx + CTLS_PATH], r12
        mov     [rbx + CTLS_FRAME_MAX], r13
        mov     [rbx + CTLS_LOOP], r14
        mov     [rbx + CTLS_RT], r15

        ; Every slot starts free. Zero is a valid descriptor, so -1 is the mark.
        xor     rcx, rcx
.clear:
        cmp     rcx, AF_CTL_MAX_CLIENTS
        jae     .cleared
        mov     rax, rcx
        imul    rax, rax, CONN_SIZE
        add     rax, rbx
        add     rax, CTLS_CONNS
        mov     qword [rax + CONN_FD], -1
        inc     rcx
        jmp     .clear
.cleared:

        mov     rdi, r12
        lea     rsi, [rsp]
        call    af_ctl_bind
        test    rax, rax
        js      .done
        mov     rax, [rsp]
        mov     [rbx + CTLS_LISTEN_FD], rax

        mov     rdi, r14
        mov     rsi, rax
        mov     rdx, EPOLLIN
        lea     rcx, [af_ctl_on_listen]
        mov     r8, rbx
        call    af_loop_add
        test    rax, rax
        js      .unbind
        AF_LEAVE_OK

.unbind:
        mov     [rsp + 8], rax
        mov     rdi, [rbx + CTLS_PATH]
        mov     rsi, [rbx + CTLS_LISTEN_FD]
        call    af_ctl_unbind
        mov     qword [rbx + CTLS_LISTEN_FD], -1
        mov     rax, [rsp + 8]
        AF_LEAVE
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_server_shutdown(af_ctl_server *s) -> void
;
; Closes every client, then the listener, then removes the socket node. In that
; order: a client still connected when the node disappears would otherwise be
; left holding a descriptor to a socket nobody can find.
; ---------------------------------------------------------------------------
        global af_ctl_server_shutdown
af_ctl_server_shutdown:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi

        xor     r12, r12
.close_clients:
        cmp     r12, AF_CTL_MAX_CLIENTS
        jae     .clients_closed
        mov     rax, r12
        imul    rax, rax, CONN_SIZE
        add     rax, rbx
        add     rax, CTLS_CONNS
        cmp     qword [rax + CONN_FD], 0
        jl      .next_client
        mov     rdi, rax
        call    af_ctl_conn_release
.next_client:
        inc     r12
        jmp     .close_clients
.clients_closed:

        mov     rax, [rbx + CTLS_LISTEN_FD]
        cmp     rax, 0
        jl      .done
        mov     rdi, [rbx + CTLS_LOOP]
        mov     rsi, rax
        call    af_loop_del
        mov     rdi, [rbx + CTLS_PATH]
        mov     rsi, [rbx + CTLS_LISTEN_FD]
        call    af_ctl_unbind
        mov     qword [rbx + CTLS_LISTEN_FD], -1
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_slot_alloc(af_ctl_server *s) -> af_ctl_conn * (NULL when full)
; ---------------------------------------------------------------------------
        global af_ctl_slot_alloc
af_ctl_slot_alloc:
        xor     ecx, ecx
.loop:
        cmp     rcx, AF_CTL_MAX_CLIENTS
        jae     .none
        mov     rax, rcx
        imul    rax, rax, CONN_SIZE
        add     rax, rdi
        add     rax, CTLS_CONNS
        cmp     qword [rax + CONN_FD], 0
        jl      .found
        inc     rcx
        jmp     .loop
.found:
        ret
.none:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_ctl_conn_release(af_ctl_conn *c) -> void
;
; The single close path. Deregisters, closes, frees both buffers, and marks the
; slot free. Every failure route in this file ends here, which is what makes the
; descriptor accounting hold.
; ---------------------------------------------------------------------------
        global af_ctl_conn_release
af_ctl_conn_release:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rax, [rbx + CONN_FD]
        cmp     rax, 0
        jl      .buffers                ; already released

        mov     r12, [rbx + CONN_SERVER]
        test    r12, r12
        jz      .no_loop
        mov     rdi, [r12 + CTLS_LOOP]
        mov     rsi, rax
        call    af_loop_del
.no_loop:
        ; Deregister first, then close. A descriptor closed while still
        ; registered is dropped from the interest set by the kernel, but an
        ; event already queued for it would still be delivered.
        mov     rdi, [rbx + CONN_FD]
        call    af_sys_close
        mov     qword [rbx + CONN_FD], -1

.buffers:
        lea     rdi, [rbx + CONN_INBOX]
        call    af_buf_free
        lea     rdi, [rbx + CONN_OUTBOX]
        call    af_buf_free
        mov     qword [rbx + CONN_OUT_CURSOR], 0
        mov     qword [rbx + CONN_CLOSING], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_on_listen(void *ctx, i64 fd, u64 events) -> void
;
; The accept handler. Drains the backlog in one pass so a burst of connections
; does not need one loop iteration each.
; ---------------------------------------------------------------------------
        global af_ctl_on_listen
af_ctl_on_listen:
        AF_ENTER 32
        mov     rbx, rdi                ; server
        mov     r12, rsi                ; listen fd

.accept_loop:
        mov     rdi, r12
        xor     esi, esi                ; no peer address needed
        xor     edx, edx
        mov     rcx, SOCK_NONBLOCK | SOCK_CLOEXEC
        call    af_sys_accept4
        test    rax, rax
        js      .accept_done            ; EAGAIN: the backlog is drained
        mov     r13, rax                ; accepted fd

        mov     rdi, rbx
        call    af_ctl_slot_alloc
        test    rax, rax
        jz      .table_full
        mov     r14, rax                ; connection slot

        mov     rdi, r14
        mov     rsi, CONN_SIZE
        call    af_mem_zero
        mov     [r14 + CONN_FD], r13
        mov     [r14 + CONN_SERVER], rbx

        lea     rdi, [r14 + CONN_INBOX]
        mov     rsi, [rbx + CTLS_FRAME_MAX]
        call    af_buf_init
        test    rax, rax
        js      .drop
        ; The outbox holds one response, which the dispatcher has already
        ; bounded, plus room for the terminator.
        lea     rdi, [r14 + CONN_OUTBOX]
        mov     rsi, [rbx + CTLS_FRAME_MAX]
        call    af_buf_init
        test    rax, rax
        js      .drop

        mov     rdi, r14
        call    af_ctl_read_peer_credentials

        mov     rdi, [rbx + CTLS_LOOP]
        mov     rsi, r13
        mov     rdx, EPOLLIN | EPOLLRDHUP
        lea     rcx, [af_ctl_on_conn]
        mov     r8, r14
        call    af_loop_add
        test    rax, rax
        js      .drop

        inc     qword [rbx + CTLS_ACCEPTED]
        jmp     .accept_loop

.table_full:
        ; Refusing is the bounded behaviour: accepting and then failing would
        ; leave the descriptor open until the client noticed.
        inc     qword [rbx + CTLS_REJECTED]
        mov     rdi, r13
        call    af_sys_close
        jmp     .accept_loop

.drop:
        mov     rdi, r14
        call    af_ctl_conn_release
        jmp     .accept_loop

.accept_done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_read_peer_credentials(af_ctl_conn *c) -> void
;
; SO_PEERCRED, recorded for the audit trail. It is NOT an authorisation check:
; the socket's 0600 mode is what restricts access, and SECURITY_MODEL.md 7 is
; explicit that loopback and file permissions are the boundary rather than any
; identity a peer asserts. A failure to read it is not fatal.
; ---------------------------------------------------------------------------
        global af_ctl_read_peer_credentials
af_ctl_read_peer_credentials:
        AF_ENTER 32
        mov     rbx, rdi
        ; struct ucred { pid_t pid; uid_t uid; gid_t gid; }
        mov     qword [rsp], 0
        mov     qword [rsp + 8], 0
        mov     dword [rsp + 16], 12
        mov     rdi, [rbx + CONN_FD]
        mov     rsi, SOL_SOCKET
        mov     rdx, SO_PEERCRED
        lea     rcx, [rsp]
        lea     r8, [rsp + 16]
        call    af_sys_getsockopt
        test    rax, rax
        js      .done
        mov     eax, [rsp]
        mov     [rbx + CONN_PEER_PID], rax
        mov     eax, [rsp + 4]
        mov     [rbx + CONN_PEER_UID], rax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_on_conn(void *ctx, i64 fd, u64 events) -> void
; ---------------------------------------------------------------------------
        global af_ctl_on_conn
af_ctl_on_conn:
        AF_ENTER 16
        mov     rbx, rdi                ; connection
        mov     r13, rdx                ; event mask

        test    r13, EPOLLOUT
        jz      .no_write
        mov     rdi, rbx
        call    af_ctl_conn_flush
        test    rax, rax
        js      .close
.no_write:

        test    r13, EPOLLIN
        jnz     .read
        test    r13, EPOLLRDHUP | EPOLLHUP | EPOLLERR
        jnz     .close
        jmp     .done

.read:
        mov     rdi, rbx
        call    af_ctl_conn_read
        test    rax, rax
        js      .close
        mov     rdi, rbx
        call    af_ctl_conn_drain_frames
        test    rax, rax
        js      .close
        mov     rdi, rbx
        call    af_ctl_conn_flush
        test    rax, rax
        js      .close

        ; A connection told to close finishes writing first, so the client sees
        ; the error that caused it.
        cmp     qword [rbx + CONN_CLOSING], 0
        je      .done
        lea     rdi, [rbx + CONN_OUTBOX]
        call    af_buf_len
        cmp     rax, [rbx + CONN_OUT_CURSOR]
        ja      .done
        jmp     .close

.close:
        mov     rdi, rbx
        call    af_ctl_conn_release
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_conn_read(af_ctl_conn *c) -> af_status
;
; Reads what is available into the inbox. AF_E_EOF when the peer closed.
; ---------------------------------------------------------------------------
        global af_ctl_conn_read
af_ctl_conn_read:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, [rbx + CONN_SERVER]

.loop:
        lea     rdi, [rbx + CONN_INBOX]
        call    af_buf_len
        mov     r13, rax
        mov     r14, [r12 + CTLS_FRAME_MAX]
        sub     r14, r13
        jbe     .at_ceiling
        cmp     r14, AF_CTL_READ_CHUNK
        jbe     .have_chunk
        mov     r14, AF_CTL_READ_CHUNK
.have_chunk:
        lea     rdi, [rbx + CONN_INBOX]
        mov     rsi, r14
        call    af_buf_reserve
        test    rax, rax
        js      .done

        lea     rdi, [rbx + CONN_INBOX]
        call    af_buf_data
        add     rax, r13
        mov     rdi, [rbx + CONN_FD]
        mov     rsi, rax
        mov     rdx, r14
        call    af_sys_read
        test    rax, rax
        jz      .peer_closed
        js      .read_error
        add     r13, rax
        lea     rcx, [rbx + CONN_INBOX]
        mov     [rcx + 8], r13          ; af_buffer.len
        jmp     .loop

.at_ceiling:
        ; The inbox is full and still has no complete frame. The framer will
        ; report the overflow; returning success lets it do so with a message
        ; rather than closing silently here.
        AF_LEAVE_OK
.peer_closed:
        AF_LEAVE_ERR AF_E_EOF
.read_error:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_AGAIN
        je      .drained
        cmp     rax, AF_E_INTR
        je      .loop
        AF_LEAVE
.drained:
        AF_LEAVE_OK
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_conn_drain_frames(af_ctl_conn *c) -> af_status
;
; Handles every complete frame the last read produced.
; ---------------------------------------------------------------------------
        global af_ctl_conn_drain_frames
af_ctl_conn_drain_frames:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, [rbx + CONN_SERVER]
.loop:
        cmp     qword [rbx + CONN_CLOSING], 0
        jne     .ok
        lea     rdi, [rbx + CONN_INBOX]
        mov     rsi, [r12 + CTLS_FRAME_MAX]
        lea     rdx, [rsp]
        lea     rcx, [rsp + 8]
        call    af_ctl_frame_next
        cmp     rax, AF_E_AGAIN
        je      .ok
        test    rax, rax
        js      .protocol_error

        mov     rdi, rbx
        mov     rsi, [rsp]
        mov     rdx, [rsp + 8]
        call    af_ctl_dispatch_frame
        mov     [rsp + 16], rax

        lea     rdi, [rbx + CONN_INBOX]
        mov     rsi, [rsp + 8]
        call    af_ctl_frame_consume
        inc     qword [rbx + CONN_FRAMES]

        mov     rax, [rsp + 16]
        test    rax, rax
        js      .done
        jmp     .loop

.protocol_error:
        ; An oversized or non-UTF-8 frame leaves the framer unable to find where
        ; the next message starts, so one error goes out and the connection ends.
        mov     [rsp + 16], rax
        mov     rdi, rbx
        mov     rsi, rax
        call    af_ctl_write_protocol_error
        mov     qword [rbx + CONN_CLOSING], 1
        lea     rdi, [rbx + CONN_INBOX]
        call    af_buf_clear
        AF_LEAVE_OK
.ok:
        AF_LEAVE_OK
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_ctl_conn_flush(af_ctl_conn *c) -> af_status
;
; Writes as much of the outbox as the socket accepts, and adjusts the loop's
; interest so the daemon is not woken for a socket it has nothing to say to.
; ---------------------------------------------------------------------------
        global af_ctl_conn_flush
af_ctl_conn_flush:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, [rbx + CONN_SERVER]
.loop:
        lea     rdi, [rbx + CONN_OUTBOX]
        call    af_buf_len
        mov     r13, rax
        mov     r14, [rbx + CONN_OUT_CURSOR]
        cmp     r14, r13
        jae     .drained

        lea     rdi, [rbx + CONN_OUTBOX]
        call    af_buf_data
        add     rax, r14
        mov     rdi, [rbx + CONN_FD]
        mov     rsi, rax
        mov     rdx, r13
        sub     rdx, r14
        call    af_sys_write
        test    rax, rax
        js      .write_error
        add     [rbx + CONN_OUT_CURSOR], rax
        jmp     .loop

.drained:
        ; Everything is out; reclaim the buffer and drop EPOLLOUT.
        lea     rdi, [rbx + CONN_OUTBOX]
        call    af_buf_clear
        mov     qword [rbx + CONN_OUT_CURSOR], 0
        mov     rdi, [r12 + CTLS_LOOP]
        mov     rsi, [rbx + CONN_FD]
        mov     rdx, EPOLLIN | EPOLLRDHUP
        call    af_loop_mod
        AF_LEAVE_OK

.write_error:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_AGAIN
        je      .would_block
        cmp     rax, AF_E_INTR
        je      .loop
        AF_LEAVE
.would_block:
        ; The client is not reading. Ask to be told when it is, and let the
        ; backpressure sit on that connection rather than on the daemon.
        mov     rdi, [r12 + CTLS_LOOP]
        mov     rsi, [rbx + CONN_FD]
        mov     rdx, EPOLLIN | EPOLLOUT | EPOLLRDHUP
        call    af_loop_mod
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; Accessors used by the dispatcher and by tests.
; ---------------------------------------------------------------------------
        global af_ctl_conn_outbox
af_ctl_conn_outbox:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        lea     rax, [rdi + CONN_OUTBOX]
.done:
        ret

        global af_ctl_conn_server
af_ctl_conn_server:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CONN_SERVER]
.done:
        ret

        global af_ctl_server_runtime
af_ctl_server_runtime:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CTLS_RT]
.done:
        ret

        global af_ctl_server_frame_max
af_ctl_server_frame_max:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CTLS_FRAME_MAX]
.done:
        ret

        global af_ctl_server_revision
af_ctl_server_revision:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CTLS_REVISION]
.done:
        ret

        global af_ctl_server_bump_revision
af_ctl_server_bump_revision:
        test    rdi, rdi
        jz      .done
        inc     qword [rdi + CTLS_REVISION]
.done:
        ret

        global af_ctl_server_accepted
af_ctl_server_accepted:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CTLS_ACCEPTED]
.done:
        ret

        global af_ctl_server_rejected
af_ctl_server_rejected:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + CTLS_REJECTED]
.done:
        ret

; af_ctl_server_open_connections(af_ctl_server *s) -> u64
;   The FD-leak soak reads this: after a hundred connect/disconnect cycles it
;   must be zero.
        global af_ctl_server_open_connections
af_ctl_server_open_connections:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        xor     ecx, ecx
        xor     edx, edx
.loop:
        cmp     rcx, AF_CTL_MAX_CLIENTS
        jae     .finished
        mov     rax, rcx
        imul    rax, rax, CONN_SIZE
        add     rax, rdi
        add     rax, CTLS_CONNS
        cmp     qword [rax + CONN_FD], 0
        jl      .skip
        inc     rdx
.skip:
        inc     rcx
        jmp     .loop
.finished:
        mov     rax, rdx
.done:
        ret

        global af_ctl_server_struct_size
af_ctl_server_struct_size:
        mov     rax, CTLS_SIZE
        ret

        global af_ctl_conn_struct_size
af_ctl_conn_struct_size:
        mov     eax, CONN_SIZE
        ret
