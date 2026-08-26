; AsmFlow — the data-plane TCP listener and connection lifecycle.
;
; The shape mirrors the control socket, for the same reasons and with the same
; guarantees: a bounded connection table so a peer opening sockets in a loop is
; refused rather than allowed to exhaust the process's descriptors, one release
; function that every close path runs through so the descriptor accounting is
; arranged rather than hoped for, and drained writes so a client that stops
; reading blocks itself instead of the daemon.
;
; Three things are specific to this listener.
;
; The address is a literal or it is nothing. `listener.host` is parsed as an
; IPv4 dotted quad, an IPv6 literal, or the name `localhost`; a hostname is
; refused. Resolving a name to decide what to bind means the daemon's exposure
; depends on a DNS answer, which is not a thing a listener should defer to.
;
; A non-loopback listener without an authentication policy is refused here as
; well as at configuration load. The load-time check catches the file; this one
; catches everything else, including a snapshot that reached the listener by any
; other route (HARNESS.md M5 DoD 8).
;
; The idle timeout is one timerfd sweeping the table (ADR 0010). A timer per
; connection would be a descriptor per connection, and the property being
; enforced — no connection may sit inactive longer than the timeout — is a
; property of the table rather than of any one member of it.

        bits 64
        default rel

%include "asmflow.inc"
%include "http.inc"
%include "socket.inc"
%include "config.inc"
%include "loop.inc"
%include "runtime.inc"

        extern af_mem_zero
        extern af_mem_eq
        extern af_cstr_len

        extern af_buf_init
        extern af_buf_append
        extern af_buf_free
        extern af_buf_clear
        extern af_buf_data
        extern af_buf_len
        extern af_buf_consume

        extern af_loop_add
        extern af_loop_mod
        extern af_loop_del

        extern af_sys_socket
        extern af_sys_bind
        extern af_sys_listen
        extern af_sys_accept4
        extern af_sys_setsockopt
        extern af_sys_close
        extern af_sys_shutdown
        extern af_sys_read
        extern af_sys_write
        extern af_sys_timerfd_create
        extern af_sys_timerfd_settime
        extern af_status_from_errno

        extern af_monotonic_ns
        extern af_cfg_getenv
        extern af_cfg_is_loopback_host

        extern af_llhttp_parser_size
        extern af_llhttp_request_init
        extern af_llhttp_execute
        extern af_llhttp_errno
        extern af_llhttp_error_offset

        extern af_http_fault
        extern af_http_reset_message
        extern af_http_send_error
        extern af_http_commit

        section .rodata

h_authorization: db "Authorization", 0
host_localhost:  db "localhost"

        section .text

; ---------------------------------------------------------------------------
; af_http_parse_ipv4(const char *s, u64 len, u32 *out_network_order)
;   -> af_status
;
; Four decimal octets separated by dots, each without a leading zero beyond a
; single "0". "010.0.0.1" is refused: some resolvers read a leading zero as
; octal, and an address whose meaning depends on who parses it is not an
; address a listener should bind.
; ---------------------------------------------------------------------------
        global af_http_parse_ipv4
af_http_parse_ipv4:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        xor     r14, r14                        ; assembled address
        xor     r15, r15                        ; cursor
        xor     ecx, ecx                        ; octet index
        mov     [rsp], rcx
.octet:
        xor     eax, eax                        ; value
        xor     edx, edx                        ; digits
.digits:
        cmp     r15, r12
        jae     .octet_done
        movzx   ecx, byte [rbx + r15]
        cmp     cl, '.'
        je      .octet_done
        sub     ecx, '0'
        cmp     ecx, 9
        ja      .invalid
        cmp     edx, 3
        jae     .invalid
        ; A second digit after a leading zero would make this ambiguous.
        test    edx, edx
        jz      .accumulate
        test    eax, eax
        jz      .invalid
.accumulate:
        imul    eax, eax, 10
        add     eax, ecx
        inc     edx
        inc     r15
        jmp     .digits
.octet_done:
        test    edx, edx
        jz      .invalid
        cmp     eax, 255
        ja      .invalid
        shl     r14, 8
        or      r14, rax
        mov     rcx, [rsp]
        inc     rcx
        mov     [rsp], rcx
        cmp     rcx, 4
        je      .assembled
        ; Another octet must follow, so a dot must be here.
        cmp     r15, r12
        jae     .invalid
        cmp     byte [rbx + r15], '.'
        jne     .invalid
        inc     r15
        jmp     .octet
.assembled:
        cmp     r15, r12
        jne     .invalid
        ; Host order to network order.
        mov     eax, r14d
        bswap   eax
        mov     [r13], eax
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_http_parse_ipv6(const char *s, u64 len, u8 *out16) -> af_status
;
; Hexadecimal groups with at most one `::`. The IPv4-in-IPv6 dotted tail and
; zone identifiers are not accepted: neither is needed to bind a listener, and
; each is a parsing rule that could disagree with the kernel's.
; ---------------------------------------------------------------------------
        global af_http_parse_ipv6
af_http_parse_ipv6:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        cmp     r12, 2
        jb      .invalid
        cmp     r12, 45
        ja      .invalid

        mov     rdi, r13
        mov     rsi, 16
        call    af_mem_zero

        xor     r14, r14                        ; cursor
        xor     r15, r15                        ; groups written before "::"
        mov     qword [rsp], -1                 ; index of the elision
        mov     qword [rsp + 8], 0              ; groups written after it
        ; Groups are staged in [rsp + 16 .. rsp + 48) as 8 x u16.

        ; A leading "::" is the only place a colon may start the string.
        cmp     byte [rbx], ':'
        jne     .groups
        cmp     byte [rbx + 1], ':'
        jne     .invalid
        mov     qword [rsp], 0
        add     r14, 2
        cmp     r14, r12
        je      .assemble

.groups:
        cmp     r14, r12
        jae     .assemble
        ; Parse one group of one to four hex digits.
        xor     eax, eax
        xor     edx, edx
.hex:
        cmp     r14, r12
        jae     .group_done
        movzx   ecx, byte [rbx + r14]
        cmp     cl, ':'
        je      .group_done
        mov     r8d, ecx
        sub     r8d, '0'
        cmp     r8d, 9
        jbe     .digit
        mov     r8d, ecx
        or      r8d, 0x20                       ; fold case
        sub     r8d, 'a'
        cmp     r8d, 5
        ja      .invalid
        add     r8d, 10
.digit:
        cmp     edx, 4
        jae     .invalid
        shl     eax, 4
        or      eax, r8d
        inc     edx
        inc     r14
        jmp     .hex
.group_done:
        test    edx, edx
        jz      .invalid
        cmp     r15, 8
        jae     .invalid
        mov     rcx, r15
        mov     [rsp + 16 + rcx * 2], ax
        inc     r15
        cmp     r14, r12
        jae     .assemble
        ; A colon is here. Either it separates groups or it opens the elision.
        inc     r14
        cmp     r14, r12
        jae     .invalid                        ; a trailing single colon
        cmp     byte [rbx + r14], ':'
        jne     .groups
        cmp     qword [rsp], -1
        jne     .invalid                        ; a second "::"
        mov     [rsp], r15
        inc     r14
        cmp     r14, r12
        je      .assemble
        jmp     .groups

.assemble:
        cmp     qword [rsp], -1
        jne     .elided
        cmp     r15, 8
        jne     .invalid
        xor     rcx, rcx
.copy_full:
        cmp     rcx, 8
        jae     .done_ok
        movzx   eax, word [rsp + 16 + rcx * 2]
        mov     r11d, eax
        shr     r11d, 8
        mov     [r13 + rcx * 2], r11b
        mov     [r13 + rcx * 2 + 1], al
        inc     rcx
        jmp     .copy_full

.elided:
        ; "::" must stand for at least one zero group.
        cmp     r15, 8
        jae     .invalid
        mov     r8, [rsp]                       ; groups before the elision
        xor     rcx, rcx
.copy_head:
        cmp     rcx, r8
        jae     .head_done
        movzx   eax, word [rsp + 16 + rcx * 2]
        mov     r11d, eax
        shr     r11d, 8
        mov     [r13 + rcx * 2], r11b
        mov     [r13 + rcx * 2 + 1], al
        inc     rcx
        jmp     .copy_head
.head_done:
        ; The tail sits flush against the end of the address.
        mov     r9, r15
        sub     r9, r8                          ; groups after the elision
        mov     rcx, 0
.copy_tail:
        cmp     rcx, r9
        jae     .done_ok
        mov     rdx, r8
        add     rdx, rcx
        movzx   eax, word [rsp + 16 + rdx * 2]
        mov     r11d, eax
        shr     r11d, 8
        mov     rdx, 8
        sub     rdx, r9
        add     rdx, rcx
        mov     [r13 + rdx * 2], r11b
        mov     [r13 + rdx * 2 + 1], al
        inc     rcx
        jmp     .copy_tail

.done_ok:
        AF_LEAVE_OK
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_http_bind(const char *host, u64 port, i64 *out_fd) -> af_status
;
; SO_REUSEADDR is set so a restart does not have to wait out TIME_WAIT.
; SO_REUSEPORT deliberately is not: it would let a second process silently take
; a share of this listener's traffic.
; ---------------------------------------------------------------------------
        global af_http_bind
af_http_bind:
        AF_ENTER 96
        test    rdi, rdi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        cmp     rsi, 65535
        ja      .invalid
        mov     rbx, rdi                        ; host
        mov     r12, rsi                        ; port
        mov     r13, rdx                        ; out fd
        mov     qword [r13], -1

        ; [rsp + 0 .. 32)   sockaddr, either family
        ; [rsp + 32]        address length
        ; [rsp + 40]        family
        ; [rsp + 48]        the listening descriptor
        ; [rsp + 56]        SO_REUSEADDR operand
        lea     rdi, [rsp]
        mov     rsi, 32
        call    af_mem_zero

        mov     rdi, rbx
        call    af_cstr_len
        mov     r14, rax
        test    r14, r14
        jz      .invalid

        ; `localhost` is a name, but it is the one name the configuration
        ; contract already recognises, so it is honoured without a resolver.
        cmp     r14, 9
        jne     .try_ipv4
        mov     rdi, rbx
        lea     rsi, [host_localhost]
        mov     rdx, 9
        call    af_mem_eq
        test    rax, rax
        jz      .try_ipv4
        mov     dword [rsp + SIN_ADDR], 0x0100007F      ; 127.0.0.1
        jmp     .ipv4_ready

.try_ipv4:
        mov     rdi, rbx
        mov     rsi, r14
        lea     rdx, [rsp + SIN_ADDR]
        call    af_http_parse_ipv4
        test    rax, rax
        js      .try_ipv6
.ipv4_ready:
        mov     word [rsp + SIN_FAMILY], AF_INET
        mov     eax, r12d
        xchg    al, ah
        mov     [rsp + SIN_PORT], ax
        mov     qword [rsp + 32], SIN_SIZE
        mov     qword [rsp + 40], AF_INET
        jmp     .have_address

.try_ipv6:
        lea     rdi, [rsp]
        mov     rsi, 32
        call    af_mem_zero
        mov     rdi, rbx
        mov     rsi, r14
        lea     rdx, [rsp + SIN6_ADDR]
        call    af_http_parse_ipv6
        test    rax, rax
        js      .not_an_address
        mov     word [rsp + SIN6_FAMILY], AF_INET6
        mov     eax, r12d
        xchg    al, ah
        mov     [rsp + SIN6_PORT], ax
        mov     qword [rsp + 32], SIN6_SIZE
        mov     qword [rsp + 40], AF_INET6

.have_address:
        mov     rdi, [rsp + 40]
        mov     rsi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
        xor     edx, edx
        call    af_sys_socket
        test    rax, rax
        js      .syscall_failed
        mov     [rsp + 48], rax

        mov     dword [rsp + 56], 1
        mov     rdi, [rsp + 48]
        mov     rsi, SOL_SOCKET
        mov     rdx, SO_REUSEADDR
        lea     rcx, [rsp + 56]
        mov     r8, 4
        call    af_sys_setsockopt

        mov     rdi, [rsp + 48]
        lea     rsi, [rsp]
        mov     rdx, [rsp + 32]
        call    af_sys_bind
        test    rax, rax
        js      .bind_failed

        mov     rdi, [rsp + 48]
        mov     rsi, 128
        call    af_sys_listen
        test    rax, rax
        js      .bind_failed

        mov     rax, [rsp + 48]
        mov     [r13], rax
        AF_LEAVE_OK

.bind_failed:
        mov     [rsp + 64], rax
        mov     rdi, [rsp + 48]
        call    af_sys_close
        mov     rdi, [rsp + 64]
        call    af_status_from_errno
        AF_LEAVE
.syscall_failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.not_an_address:
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_http_server_init(af_http_server *s, af_config *cfg, af_loop *loop,
;                     void *rt) -> af_status
;
; Ownership: `cfg`, `loop`, and `rt` are BORROWED and must outlive the server.
; The auth secret is borrowed from the environment, which the process owns for
; its whole life.
; ---------------------------------------------------------------------------
        global af_http_server_init
af_http_server_init:
        AF_ENTER 64
        test    rdi, rdi
        jz      .invalid
        test    rsi, rsi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        mov     rbx, rdi                        ; server
        mov     r12, rsi                        ; configuration
        mov     r13, rdx                        ; loop
        mov     r14, rcx                        ; runtime

        ; The parser field is a fixed size and llhttp's state is whatever the
        ; linked library says. Refusing to start is the only safe answer to a
        ; mismatch; the alternative is writing past the field at the first
        ; request.
        call    af_llhttp_parser_size
        cmp     rax, AF_HTTP_PARSER_MAX
        ja      .parser_too_large

        mov     rdi, rbx
        mov     rsi, HS_SIZE
        call    af_mem_zero
        mov     qword [rbx + HS_LISTEN_FD], -1
        mov     qword [rbx + HS_TIMER_FD], -1
        mov     [rbx + HS_LOOP], r13
        mov     [rbx + HS_RT], r14

        mov     rax, [r12 + CFG_LST_HDR_MAX]
        mov     [rbx + HS_HEADER_MAX], rax
        mov     rax, [r12 + CFG_LST_BODY_MAX]
        mov     [rbx + HS_BODY_MAX], rax
        mov     rax, [r12 + CFG_LST_IDLE_MS]
        mov     [rbx + HS_IDLE_MS], rax
        mov     rax, [r12 + CFG_LST_PORT]
        mov     [rbx + HS_PORT], rax

        mov     rdi, rbx
        mov     rsi, r12
        call    af_http_resolve_auth
        test    rax, rax
        js      .done

        ; The rule the configuration also enforces, restated where the socket is
        ; actually created. A listener that is about to accept from beyond this
        ; host with no credential policy does not open.
        cmp     qword [r12 + CFG_LST_IS_LOOPBACK], 0
        jne     .exposure_ok
        cmp     qword [rbx + HS_AUTH_TYPE], AF_AUTH_NONE
        je      .exposed_without_auth
.exposure_ok:

        ; Every slot starts free. Zero is a valid descriptor, so -1 is the mark.
        xor     rcx, rcx
.clear:
        cmp     rcx, AF_HTTP_MAX_CLIENTS
        jae     .cleared
        mov     rax, rcx
        imul    rax, rax, HC_SIZE
        add     rax, rbx
        add     rax, HS_CONNS
        mov     qword [rax + HC_FD], -1
        inc     rcx
        jmp     .clear
.cleared:

        mov     rdi, [r12 + CFG_LST_HOST]
        mov     rsi, [r12 + CFG_LST_PORT]
        lea     rdx, [rsp]
        call    af_http_bind
        test    rax, rax
        js      .done
        mov     rax, [rsp]
        mov     [rbx + HS_LISTEN_FD], rax

        mov     rdi, r13
        mov     rsi, rax
        mov     rdx, EPOLLIN
        lea     rcx, [af_http_on_listen]
        mov     r8, rbx
        call    af_loop_add
        test    rax, rax
        js      .close_listener

        mov     rdi, rbx
        call    af_http_start_idle_timer
        test    rax, rax
        js      .deregister
        AF_LEAVE_OK

.deregister:
        mov     [rsp + 8], rax
        mov     rdi, r13
        mov     rsi, [rbx + HS_LISTEN_FD]
        call    af_loop_del
        mov     rax, [rsp + 8]
.close_listener:
        mov     [rsp + 8], rax
        mov     rdi, [rbx + HS_LISTEN_FD]
        call    af_sys_close
        mov     qword [rbx + HS_LISTEN_FD], -1
        mov     rax, [rsp + 8]
        AF_LEAVE
.parser_too_large:
        AF_LEAVE_ERR AF_E_UNSUPPORTED
.exposed_without_auth:
        AF_LEAVE_ERR AF_E_CFG_SCHEMA
.invalid:
        AF_LEAVE_ERR AF_E_INVALID
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_resolve_auth(af_http_server *s, af_config *cfg) -> af_status
;
; Reads the policy into the server, including the secret's value. The value is
; read once, here, rather than on every request: a request path that calls
; getenv is a request path whose behaviour depends on something outside the
; snapshot it is serving.
; ---------------------------------------------------------------------------
        global af_http_resolve_auth
af_http_resolve_auth:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, rsi

        mov     rax, [r12 + CFG_LST_AUTH + AUTH_TYPE]
        mov     [rbx + HS_AUTH_TYPE], rax
        mov     qword [rbx + HS_AUTH_HEADER], 0
        mov     qword [rbx + HS_AUTH_SECRET], 0
        mov     qword [rbx + HS_AUTH_SECRET_LEN], 0
        cmp     rax, AF_AUTH_NONE
        je      .ok

        cmp     rax, AF_AUTH_BEARER_ENV
        jne     .named_header
        lea     rax, [h_authorization]
        mov     [rbx + HS_AUTH_HEADER], rax
        jmp     .read_secret
.named_header:
        mov     rax, [r12 + CFG_LST_AUTH + AUTH_HEADER]
        test    rax, rax
        jz      .invalid
        mov     [rbx + HS_AUTH_HEADER], rax

.read_secret:
        mov     rdi, [r12 + CFG_LST_AUTH + AUTH_ENV]
        test    rdi, rdi
        jz      .invalid
        call    af_cfg_getenv
        test    rax, rax
        jz      .secret_missing
        mov     [rbx + HS_AUTH_SECRET], rax
        mov     rdi, rax
        call    af_cstr_len
        test    rax, rax
        jz      .secret_missing
        mov     [rbx + HS_AUTH_SECRET_LEN], rax
.ok:
        AF_LEAVE_OK
.secret_missing:
        AF_LEAVE_ERR AF_E_CFG_SECRET_MISSING
.invalid:
        AF_LEAVE_ERR AF_E_INVALID

; ---------------------------------------------------------------------------
; af_http_start_idle_timer(af_http_server *s) -> af_status
; ---------------------------------------------------------------------------
        global af_http_start_idle_timer
af_http_start_idle_timer:
        AF_ENTER 64
        mov     rbx, rdi
        mov     rdi, CLOCK_MONOTONIC
        mov     rsi, TFD_NONBLOCK | TFD_CLOEXEC
        call    af_sys_timerfd_create
        test    rax, rax
        js      .syscall_failed
        mov     [rbx + HS_TIMER_FD], rax

        ; struct itimerspec { timespec interval; timespec value; }
        lea     rdi, [rsp]
        mov     rsi, 32
        call    af_mem_zero
        mov     qword [rsp], 0
        mov     qword [rsp + 8], AF_HTTP_IDLE_TICK_MS * 1000000
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], AF_HTTP_IDLE_TICK_MS * 1000000

        mov     rdi, [rbx + HS_TIMER_FD]
        xor     esi, esi
        lea     rdx, [rsp]
        xor     ecx, ecx
        call    af_sys_timerfd_settime
        test    rax, rax
        js      .close_timer

        mov     rdi, [rbx + HS_LOOP]
        mov     rsi, [rbx + HS_TIMER_FD]
        mov     rdx, EPOLLIN
        lea     rcx, [af_http_on_timer]
        mov     r8, rbx
        call    af_loop_add
        test    rax, rax
        js      .close_timer
        AF_LEAVE_OK

.close_timer:
        mov     [rsp + 40], rax
        mov     rdi, [rbx + HS_TIMER_FD]
        call    af_sys_close
        mov     qword [rbx + HS_TIMER_FD], -1
        mov     rax, [rsp + 40]
        test    rax, rax
        js      .propagate
        AF_LEAVE_ERR AF_E_SYS
.propagate:
        AF_LEAVE
.syscall_failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_server_shutdown(af_http_server *s) -> void
;
; Clients first, then the timer, then the listener: a client still registered
; when the loop stops knowing about the server would be a slot nobody closes.
; ---------------------------------------------------------------------------
        global af_http_server_shutdown
af_http_server_shutdown:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi

        xor     r12, r12
.close_clients:
        cmp     r12, AF_HTTP_MAX_CLIENTS
        jae     .clients_closed
        mov     rax, r12
        imul    rax, rax, HC_SIZE
        add     rax, rbx
        add     rax, HS_CONNS
        cmp     qword [rax + HC_FD], 0
        jl      .next_client
        mov     rdi, rax
        call    af_http_conn_release
.next_client:
        inc     r12
        jmp     .close_clients
.clients_closed:

        cmp     qword [rbx + HS_TIMER_FD], 0
        jl      .timer_done
        mov     rdi, [rbx + HS_LOOP]
        mov     rsi, [rbx + HS_TIMER_FD]
        call    af_loop_del
        mov     rdi, [rbx + HS_TIMER_FD]
        call    af_sys_close
        mov     qword [rbx + HS_TIMER_FD], -1
.timer_done:

        cmp     qword [rbx + HS_LISTEN_FD], 0
        jl      .done
        mov     rdi, [rbx + HS_LOOP]
        mov     rsi, [rbx + HS_LISTEN_FD]
        call    af_loop_del
        mov     rdi, [rbx + HS_LISTEN_FD]
        call    af_sys_close
        mov     qword [rbx + HS_LISTEN_FD], -1
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_slot_alloc(af_http_server *s) -> af_http_conn * (NULL when full)
; ---------------------------------------------------------------------------
        global af_http_slot_alloc
af_http_slot_alloc:
        xor     ecx, ecx
.loop:
        cmp     rcx, AF_HTTP_MAX_CLIENTS
        jae     .none
        mov     rax, rcx
        imul    rax, rax, HC_SIZE
        add     rax, rdi
        add     rax, HS_CONNS
        cmp     qword [rax + HC_FD], 0
        jl      .found
        inc     rcx
        jmp     .loop
.found:
        ret
.none:
        xor     eax, eax
        ret

; ---------------------------------------------------------------------------
; af_http_conn_release(af_http_conn *c) -> void
;
; The single close path. Every failure route in this file ends here, which is
; what makes the descriptor accounting hold under the fault suite.
; ---------------------------------------------------------------------------
        global af_http_conn_release
af_http_conn_release:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     rax, [rbx + HC_FD]
        cmp     rax, 0
        jl      .buffers

        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .no_loop
        mov     rdi, [r12 + HS_LOOP]
        mov     rsi, rax
        call    af_loop_del
.no_loop:
        ; Deregister, then close. A descriptor closed while still registered is
        ; dropped from the interest set by the kernel, but an event already
        ; queued for it would still be delivered.
        mov     rdi, [rbx + HC_FD]
        call    af_sys_close
        mov     qword [rbx + HC_FD], -1

.buffers:
        lea     rdi, [rbx + HC_INBOX]
        call    af_buf_free
        lea     rdi, [rbx + HC_OUTBOX]
        call    af_buf_free
        lea     rdi, [rbx + HC_TARGET]
        call    af_buf_free
        lea     rdi, [rbx + HC_NAME]
        call    af_buf_free
        lea     rdi, [rbx + HC_VALUE]
        call    af_buf_free
        lea     rdi, [rbx + HC_BODY]
        call    af_buf_free
        lea     rdi, [rbx + HC_AUTH]
        call    af_buf_free
        lea     rdi, [rbx + HC_CTYPE]
        call    af_buf_free
        lea     rdi, [rbx + HC_RESPONSE]
        call    af_buf_free
        mov     qword [rbx + HC_OUT_CURSOR], 0
        mov     qword [rbx + HC_FLAGS], 0
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_conn_init_buffers(af_http_conn *c) -> af_status
;
; Each buffer carries its own ceiling, so an oversized piece is refused by the
; piece that is oversized rather than by whatever happens to notice first.
; ---------------------------------------------------------------------------
        global af_http_conn_init_buffers
af_http_conn_init_buffers:
        AF_ENTER 32
        mov     rbx, rdi
        mov     r12, [rbx + HC_SERVER]

        ; The inbox holds one header section, one body, and one read's worth of
        ; whatever followed them.
        mov     rsi, [r12 + HS_HEADER_MAX]
        add     rsi, [r12 + HS_BODY_MAX]
        add     rsi, AF_HTTP_READ_CHUNK
        lea     rdi, [rbx + HC_INBOX]
        call    af_buf_init
        test    rax, rax
        js      .done

        ; The outbox is what bounds a pipelining client: responses accumulate
        ; here, and an append that no longer fits ends the connection.
        lea     rdi, [rbx + HC_OUTBOX]
        mov     rsi, 1048576
        call    af_buf_init
        test    rax, rax
        js      .done

        lea     rdi, [rbx + HC_TARGET]
        mov     rsi, AF_HTTP_TARGET_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rdi, [rbx + HC_NAME]
        mov     rsi, AF_HTTP_NAME_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rdi, [rbx + HC_VALUE]
        mov     rsi, AF_HTTP_VALUE_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rdi, [rbx + HC_BODY]
        mov     rsi, [r12 + HS_BODY_MAX]
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rdi, [rbx + HC_AUTH]
        mov     rsi, AF_HTTP_VALUE_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rdi, [rbx + HC_CTYPE]
        mov     rsi, AF_HTTP_VALUE_MAX
        call    af_buf_init
        test    rax, rax
        js      .done
        lea     rdi, [rbx + HC_RESPONSE]
        mov     rsi, 1048576
        call    af_buf_init
        test    rax, rax
        js      .done
        or      qword [rbx + HC_FLAGS], HC_F_BUFFERS_READY
        xor     eax, eax
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_on_listen(void *ctx, i64 fd, u64 events) -> void
;
; Drains the backlog in one pass, so a burst does not need one loop iteration
; per connection.
; ---------------------------------------------------------------------------
        global af_http_on_listen
af_http_on_listen:
        AF_ENTER 32
        mov     rbx, rdi                        ; server
        mov     r12, rsi                        ; listening descriptor

.accept_loop:
        mov     rdi, r12
        xor     esi, esi
        xor     edx, edx
        mov     rcx, SOCK_NONBLOCK | SOCK_CLOEXEC
        call    af_sys_accept4
        test    rax, rax
        js      .accept_done                    ; EAGAIN: the backlog is drained
        mov     r13, rax

        mov     rdi, rbx
        call    af_http_slot_alloc
        test    rax, rax
        jz      .table_full
        mov     r14, rax

        mov     rdi, r14
        mov     rsi, HC_SIZE
        call    af_mem_zero
        mov     [r14 + HC_FD], r13
        mov     [r14 + HC_SERVER], rbx
        mov     qword [r14 + HC_CONTENT_LENGTH], -1

        mov     rdi, r14
        call    af_http_conn_init_buffers
        test    rax, rax
        js      .drop

        lea     rdi, [r14 + HC_PARSER]
        mov     rsi, r14
        call    af_llhttp_request_init

        mov     rdi, r14
        call    af_http_touch

        mov     rdi, [rbx + HS_LOOP]
        mov     rsi, r13
        mov     rdx, EPOLLIN | EPOLLRDHUP
        lea     rcx, [af_http_on_conn]
        mov     r8, r14
        call    af_loop_add
        test    rax, rax
        js      .drop

        inc     qword [rbx + HS_ACCEPTED]
        jmp     .accept_loop

.table_full:
        ; Refusing is the bounded behaviour. Accepting and then failing would
        ; leave the descriptor open until the client noticed.
        inc     qword [rbx + HS_REJECTED]
        mov     rdi, r13
        call    af_sys_close
        jmp     .accept_loop

.drop:
        mov     rdi, r14
        call    af_http_conn_release
        jmp     .accept_loop

.accept_done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_touch(af_http_conn *c) -> void
; ---------------------------------------------------------------------------
        global af_http_touch
af_http_touch:
        AF_ENTER 16
        mov     rbx, rdi
        lea     rdi, [rsp]
        mov     qword [rsp], 0
        call    af_monotonic_ns
        mov     rax, [rsp]
        mov     [rbx + HC_LAST_ACTIVE_NS], rax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_on_timer(void *ctx, i64 fd, u64 events) -> void
;
; The idle sweep (ADR 0010). A connection past its timeout is told why and then
; closed; one that has nothing queued is closed straight away, because a peer
; that has sent nothing has nothing to read either.
; ---------------------------------------------------------------------------
        global af_http_on_timer
af_http_on_timer:
        AF_ENTER 48
        mov     rbx, rdi                        ; server
        mov     r12, rsi                        ; timer descriptor

        ; Drain the expiry count, or the descriptor stays readable forever.
        mov     rdi, r12
        lea     rsi, [rsp]
        mov     rdx, 8
        call    af_sys_read

        mov     rax, [rbx + HS_IDLE_MS]
        test    rax, rax
        jz      .done
        mov     rcx, 1000000
        mul     rcx
        mov     [rsp + 8], rax                  ; the timeout, in nanoseconds

        lea     rdi, [rsp + 16]
        mov     qword [rsp + 16], 0
        call    af_monotonic_ns
        mov     r13, [rsp + 16]

        xor     r14, r14
.sweep:
        cmp     r14, AF_HTTP_MAX_CLIENTS
        jae     .done
        mov     rax, r14
        imul    rax, rax, HC_SIZE
        add     rax, rbx
        add     rax, HS_CONNS
        mov     r15, rax
        cmp     qword [r15 + HC_FD], 0
        jl      .next
        mov     rax, r13
        sub     rax, [r15 + HC_LAST_ACTIVE_NS]
        jc      .next                           ; the clock moved backwards
        cmp     rax, [rsp + 8]
        jbe     .next

        inc     qword [rbx + HS_TIMED_OUT]

        ; A connection that is mid-request is told what happened. One that has
        ; sent nothing at all, or that is already closing, just goes.
        ;
        ; "Mid-request" is the header-byte count rather than anything left in
        ; the inbox: llhttp consumes a partial header section as it arrives, so
        ; a slowloris that has sent half a request has an empty inbox and is
        ; exactly the case this branch exists for.
        test    qword [r15 + HC_FLAGS], HC_F_CLOSING
        jnz     .close_it
        cmp     qword [r15 + HC_HEADER_BYTES], 0
        je      .close_it
        test    qword [r15 + HC_FLAGS], HC_F_MESSAGE_DONE
        jnz     .close_it

        mov     rdi, r15
        mov     rsi, AF_HERR_REQUEST_TIMEOUT
        call    af_http_send_error
        or      qword [r15 + HC_FLAGS], HC_F_CLOSING
        mov     rdi, r15
        call    af_http_conn_flush
.close_it:
        mov     rdi, r15
        call    af_http_conn_release
.next:
        inc     r14
        jmp     .sweep
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_on_conn(void *ctx, i64 fd, u64 events) -> void
; ---------------------------------------------------------------------------
        global af_http_on_conn
af_http_on_conn:
        AF_ENTER 16
        mov     rbx, rdi                        ; connection
        mov     r13, rdx                        ; event mask

        test    r13, EPOLLOUT
        jz      .no_write
        mov     rdi, rbx
        call    af_http_conn_flush
        test    rax, rax
        js      .close
.no_write:

        test    r13, EPOLLIN
        jnz     .read
        test    r13, EPOLLRDHUP | EPOLLHUP | EPOLLERR
        jnz     .drain_then_close
        jmp     .maybe_close

.read:
        test    qword [rbx + HC_FLAGS], HC_F_DRAINING
        jnz     .drain_read
        mov     rdi, rbx
        call    af_http_touch
        mov     rdi, rbx
        call    af_http_conn_read
        mov     r12, rax
        test    r12, r12
        js      .read_ended
        mov     rdi, rbx
        call    af_http_conn_feed
        test    rax, rax
        js      .close
        mov     rdi, rbx
        call    af_http_conn_flush
        test    rax, rax
        js      .close
        jmp     .maybe_close

.drain_read:
        mov     rdi, rbx
        call    af_http_discard
        test    rax, rax
        js      .close
        jmp     .done

.read_ended:
        ; The peer is done sending. Whatever is already queued still goes out.
        cmp     r12, AF_E_AGAIN
        je      .maybe_close
        or      qword [rbx + HC_FLAGS], HC_F_CLOSING
        mov     rdi, rbx
        call    af_http_conn_feed
        mov     rdi, rbx
        call    af_http_conn_flush

.drain_then_close:
        ; The peer hung up. Whatever is already queued is still attempted, but
        ; this connection is over either way: without setting the flag the slot
        ; would stay registered for a socket nobody is on the other end of.
        or      qword [rbx + HC_FLAGS], HC_F_CLOSING
        mov     rdi, rbx
        call    af_http_conn_flush

.maybe_close:
        test    qword [rbx + HC_FLAGS], HC_F_CLOSING
        jz      .done
        lea     rdi, [rbx + HC_OUTBOX]
        call    af_buf_len
        cmp     rax, [rbx + HC_OUT_CURSOR]
        ja      .done                           ; finish writing first
        mov     rdi, rbx
        call    af_http_begin_drain
        test    rax, rax
        jz      .done                           ; still draining the peer
.close:
        mov     rdi, rbx
        call    af_http_conn_release
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_begin_drain(af_http_conn *c) -> i64 (1 = close it now)
;
; A refusal answered while the client is still transmitting must not be
; destroyed on its way out. Closing a socket that still has unread bytes in its
; receive queue makes the kernel send RST instead of FIN, and an RST discards
; whatever the peer has not yet read — which is exactly the response explaining
; why it was refused. So the write side is shut down, the connection is kept,
; and the rest of what the peer is sending is read and thrown away until it
; stops. The idle sweep reclaims the slot if the peer never does, and
; `last_active` is deliberately not refreshed while draining so that sweep can
; actually fire.
; ---------------------------------------------------------------------------
        global af_http_begin_drain
af_http_begin_drain:
        AF_ENTER 0
        mov     rbx, rdi
        cmp     qword [rbx + HC_FD], 0
        jl      .close_now
        test    qword [rbx + HC_FLAGS], HC_F_DRAINING
        jnz     .keep
        or      qword [rbx + HC_FLAGS], HC_F_DRAINING
        mov     rdi, [rbx + HC_FD]
        mov     rsi, SHUT_WR
        call    af_sys_shutdown
        test    rax, rax
        js      .close_now
        ; Only the read side is interesting from here on.
        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .keep
        mov     rdi, [r12 + HS_LOOP]
        mov     rsi, [rbx + HC_FD]
        mov     rdx, EPOLLIN | EPOLLRDHUP
        call    af_loop_mod
.keep:
        xor     eax, eax
        AF_LEAVE
.close_now:
        mov     eax, 1
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_discard(af_http_conn *c) -> af_status
;
; Reads and throws away. AF_E_EOF once the peer has finished, which is the
; signal that the slot can go.
; ---------------------------------------------------------------------------
        global af_http_discard
af_http_discard:
        AF_ENTER (AF_HTTP_READ_CHUNK + 16)
        mov     rbx, rdi
        mov     rdi, [rbx + HC_FD]
        lea     rsi, [rsp]
        mov     rdx, AF_HTTP_READ_CHUNK
        call    af_sys_read
        test    rax, rax
        js      .failed
        test    rax, rax
        jz      .eof
        AF_LEAVE_OK
.eof:
        AF_LEAVE_ERR AF_E_EOF
.failed:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_AGAIN
        je      .again
        AF_LEAVE
.again:
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; af_http_conn_read(af_http_conn *c) -> af_status
;
; Reads what is available into the inbox. AF_E_EOF when the peer closed,
; AF_E_AGAIN when the socket had nothing more.
; ---------------------------------------------------------------------------
        global af_http_conn_read
af_http_conn_read:
        AF_ENTER (AF_HTTP_READ_CHUNK + 64)
        mov     rbx, rdi
        mov     rdi, [rbx + HC_FD]
        lea     rsi, [rsp]
        mov     rdx, AF_HTTP_READ_CHUNK
        call    af_sys_read
        test    rax, rax
        js      .failed
        test    rax, rax
        jz      .eof
        mov     [rsp + AF_HTTP_READ_CHUNK], rax

        lea     rdi, [rbx + HC_INBOX]
        lea     rsi, [rsp]
        mov     rdx, [rsp + AF_HTTP_READ_CHUNK]
        call    af_buf_append
        test    rax, rax
        js      .overflow
        AF_LEAVE_OK

.overflow:
        ; The inbox ceiling is header_max + body_max + one read. Passing it
        ; means the peer is sending more than any legal request can contain.
        mov     rdi, rbx
        mov     rsi, AF_HERR_BODY_TOO_LARGE
        call    af_http_fault
        AF_LEAVE_ERR AF_E_HTTP_BODY_LARGE
.eof:
        AF_LEAVE_ERR AF_E_EOF
.failed:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_http_conn_feed(af_http_conn *c) -> af_status
;
; Hands the inbox to llhttp and accounts for what it consumed. The header
; ceiling is applied to the bytes that arrive before the header section ends,
; which is the only measure available while it is still arriving — the same
; reason the control plane's frame ceiling counts what accumulates rather than
; what completes.
; ---------------------------------------------------------------------------
        global af_http_conn_feed
af_http_conn_feed:
        AF_ENTER 64
        mov     rbx, rdi

        lea     rdi, [rbx + HC_INBOX]
        call    af_buf_len
        test    rax, rax
        jz      .nothing
        mov     [rsp], rax
        lea     rdi, [rbx + HC_INBOX]
        call    af_buf_data
        mov     [rsp + 8], rax
        test    rax, rax
        jz      .nothing

        ; While the header section is unfinished, feed no more than what is
        ; left of its ceiling plus one byte. Everything consumed under that cap
        ; is header section, so the count below is exact rather than an estimate
        ; that a large body would spoil, and the one extra byte is what makes
        ; exceeding the ceiling observable instead of merely reaching it.
        mov     rax, [rsp]
        mov     [rsp + 32], rax                 ; how much to feed
        test    qword [rbx + HC_FLAGS], HC_F_HEADERS_DONE
        jnz     .capped
        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .capped
        mov     rcx, [r12 + HS_HEADER_MAX]
        sub     rcx, [rbx + HC_HEADER_BYTES]
        jbe     .headers_too_large
        inc     rcx
        cmp     [rsp + 32], rcx
        jbe     .capped
        mov     [rsp + 32], rcx
.capped:

        lea     rdi, [rbx + HC_PARSER]
        mov     rsi, [rsp + 8]
        mov     rdx, [rsp + 32]
        call    af_llhttp_execute
        mov     [rsp + 16], rax                 ; llhttp errno

        cmp     dword [rsp + 16], AF_HPE_OK
        jne     .stopped

        ; Everything offered was consumed. If the header section is still
        ; unfinished, every one of those bytes belonged to it.
        mov     rdi, rbx
        mov     rsi, [rsp + 32]
        call    af_http_count_header_bytes
        test    rax, rax
        js      .headers_too_large

        lea     rdi, [rbx + HC_INBOX]
        mov     rsi, [rsp + 32]
        call    af_buf_consume
        AF_LEAVE_OK

.stopped:
        ; Consume exactly what the parser accepted, so a pipelined remainder is
        ; not replayed and not lost.
        lea     rdi, [rbx + HC_PARSER]
        mov     rsi, [rsp + 8]
        call    af_llhttp_error_offset
        cmp     rax, 0
        jl      .consume_all
        cmp     rax, [rsp]
        ja      .consume_all
        mov     [rsp + 24], rax
        jmp     .consume_counted
.consume_all:
        mov     rax, [rsp]
        mov     [rsp + 24], rax
.consume_counted:
        mov     rdi, rbx
        mov     rsi, [rsp + 24]
        call    af_http_count_header_bytes
        lea     rdi, [rbx + HC_INBOX]
        mov     rsi, [rsp + 24]
        call    af_buf_consume

        ; A message that ended with the connection closing is not an error: the
        ; dispatcher asked for the parse to stop.
        test    qword [rbx + HC_FLAGS], HC_F_CLOSING
        jnz     .ok_stop

        ; Anything else is a syntax failure. If a rule here already recorded a
        ; reason, that reason is what the client is told; otherwise the message
        ; was simply not well-formed.
        test    qword [rbx + HC_FLAGS], HC_F_FAULT
        jnz     .refuse
        mov     rdi, rbx
        mov     rsi, AF_HERR_MALFORMED
        mov     eax, [rsp + 16]
        cmp     eax, AF_HPE_UNEXPECTED_CONTENT_LENGTH
        je      .framing
        cmp     eax, AF_HPE_INVALID_CONTENT_LENGTH
        je      .framing
        cmp     eax, AF_HPE_INVALID_CHUNK_SIZE
        je      .framing
        cmp     eax, AF_HPE_INVALID_TRANSFER_ENCODING
        jne     .record_fault
.framing:
        mov     rsi, AF_HERR_SMUGGLING
.record_fault:
        call    af_http_fault

.headers_too_large:
        mov     rdi, rbx
        mov     rsi, AF_HERR_HEADERS_TOO_LARGE
        call    af_http_fault
        jmp     .refuse

.refuse:
        ; One response, then close. A framing failure means the parser can no
        ; longer say where the next message starts, so resynchronising is not
        ; something that can be attempted honestly.
        test    qword [rbx + HC_FLAGS], HC_F_RESPONDED
        jnz     .already_answered
        mov     rdi, rbx
        mov     rsi, [rbx + HC_FAULT]
        call    af_http_send_error
.already_answered:
        or      qword [rbx + HC_FLAGS], HC_F_CLOSING
        AF_LEAVE_OK
.ok_stop:
        AF_LEAVE_OK
.nothing:
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; af_http_count_header_bytes(af_http_conn *c, u64 consumed) -> af_status
;
; Adds `consumed` to the header-section total, but only while that section is
; still unfinished. Once llhttp has reported the blank line, the bytes after it
; are body and are accounted for by the body ceiling instead. AF_E_HTTP_HEADERS_LARGE
; once the total passes the configured maximum.
; ---------------------------------------------------------------------------
        global af_http_count_header_bytes
af_http_count_header_bytes:
        test    qword [rdi + HC_FLAGS], HC_F_HEADERS_DONE
        jnz     .ok
        mov     rax, [rdi + HC_HEADER_BYTES]
        add     rax, rsi
        mov     [rdi + HC_HEADER_BYTES], rax
        mov     rcx, [rdi + HC_SERVER]
        test    rcx, rcx
        jz      .ok
        cmp     rax, [rcx + HS_HEADER_MAX]
        ja      .too_large
.ok:
        xor     eax, eax
        ret
.too_large:
        mov     rax, AF_E_HTTP_HEADERS_LARGE
        ret

; ---------------------------------------------------------------------------
; af_http_conn_flush(af_http_conn *c) -> af_status
;
; Writes what it can and enables EPOLLOUT when the socket would block, so a
; client that stops reading blocks itself rather than the daemon.
; ---------------------------------------------------------------------------
        global af_http_conn_flush
af_http_conn_flush:
        AF_ENTER 48
        mov     rbx, rdi
        cmp     qword [rbx + HC_FD], 0
        jl      .done_ok

.write_loop:
        lea     rdi, [rbx + HC_OUTBOX]
        call    af_buf_len
        mov     [rsp], rax
        mov     rcx, [rbx + HC_OUT_CURSOR]
        cmp     rcx, rax
        jae     .drained

        lea     rdi, [rbx + HC_OUTBOX]
        call    af_buf_data
        test    rax, rax
        jz      .drained
        add     rax, [rbx + HC_OUT_CURSOR]
        mov     [rsp + 8], rax
        mov     rax, [rsp]
        sub     rax, [rbx + HC_OUT_CURSOR]
        mov     [rsp + 16], rax

        mov     rdi, [rbx + HC_FD]
        mov     rsi, [rsp + 8]
        mov     rdx, [rsp + 16]
        call    af_sys_write
        test    rax, rax
        js      .write_failed
        add     [rbx + HC_OUT_CURSOR], rax
        test    rax, rax
        jz      .would_block
        jmp     .write_loop

.drained:
        lea     rdi, [rbx + HC_OUTBOX]
        call    af_buf_clear
        mov     qword [rbx + HC_OUT_CURSOR], 0
        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .done_ok
        mov     rdi, [r12 + HS_LOOP]
        mov     rsi, [rbx + HC_FD]
        mov     rdx, EPOLLIN | EPOLLRDHUP
        call    af_loop_mod
        jmp     .done_ok

.would_block:
        mov     r12, [rbx + HC_SERVER]
        test    r12, r12
        jz      .done_ok
        mov     rdi, [r12 + HS_LOOP]
        mov     rsi, [rbx + HC_FD]
        mov     rdx, EPOLLIN | EPOLLOUT | EPOLLRDHUP
        call    af_loop_mod
        jmp     .done_ok

.write_failed:
        mov     rdi, rax
        call    af_status_from_errno
        cmp     rax, AF_E_AGAIN
        je      .would_block
        AF_LEAVE
.done_ok:
        AF_LEAVE_OK

; ---------------------------------------------------------------------------
; af_http_server_struct_size() -> u64
; af_http_conn_struct_size() -> u64
;
; So a test can assert what the daemon has to allocate rather than duplicating
; the arithmetic.
; ---------------------------------------------------------------------------
        global af_http_server_struct_size
af_http_server_struct_size:
        mov     rax, HS_SIZE
        ret

        global af_http_conn_struct_size
af_http_conn_struct_size:
        mov     rax, HC_SIZE
        ret
