; AsmFlow — socket constants, in one place.
;
; These are kernel ABI numbers, not AsmFlow's own. They were previously repeated
; at the top of each file that opened a socket, which was fine until two files
; needed the same name: NASM replaces a `%define` silently, so the meaning of a
; duplicated name depends on include order and nothing warns. `make check`
; rejects a name defined twice across `include/`, and this header is where the
; shared ones live so that rule has somewhere to point.
;
; Values are x86-64 Linux. `SOCK_NONBLOCK` and `SOCK_CLOEXEC` in particular are
; architecture-specific and are not the same numbers everywhere.

%ifndef ASMFLOW_SOCKET_INC
%define ASMFLOW_SOCKET_INC

; --- address families ------------------------------------------------------
%define AF_UNIX  1
%define AF_INET  2
%define AF_INET6 10

; --- socket types and the flags accept4/socket accept inline ---------------
%define SOCK_STREAM   1
%define SOCK_NONBLOCK 0x800
%define SOCK_CLOEXEC  0x80000

; --- option levels and options ---------------------------------------------
%define SOL_SOCKET   1
%define SO_REUSEADDR 2
%define SO_PEERCRED  17
%define IPPROTO_TCP  6
%define TCP_NODELAY  1

; --- shutdown ---------------------------------------------------------------
%define SHUT_RD   0
%define SHUT_WR   1
%define SHUT_RDWR 2

; --- struct sockaddr_un ----------------------------------------------------
;   { u16 family; char path[108]; }
%define SUN_FAMILY   0
%define SUN_PATH     2
%define SUN_SIZE     110
%define SUN_PATH_MAX 108

; --- struct sockaddr_in ----------------------------------------------------
;   { u16 family; u16 port_be; u32 addr_be; u8 pad[8]; }
%define SIN_FAMILY 0
%define SIN_PORT   2
%define SIN_ADDR   4
%define SIN_SIZE   16

; --- struct sockaddr_in6 ---------------------------------------------------
;   { u16 family; u16 port_be; u32 flowinfo; u8 addr[16]; u32 scope_id; }
%define SIN6_FAMILY   0
%define SIN6_PORT     2
%define SIN6_FLOWINFO 4
%define SIN6_ADDR     8
%define SIN6_SCOPE    24
%define SIN6_SIZE     28

; --- timerfd ----------------------------------------------------------------
; The clock ids themselves are in asmflow.inc, because the clock module needs
; them too.
%define TFD_NONBLOCK 0x800
%define TFD_CLOEXEC  0x80000

%endif ; ASMFLOW_SOCKET_INC
