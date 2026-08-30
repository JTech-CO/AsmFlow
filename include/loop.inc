; AsmFlow — event loop layout.
;
; ADR 0002: one event loop, one thread, no shared writable memory. Every
; registered source names a handler and a context; ownership of the context
; belongs to whoever registered it, and the loop never frees one.

%ifndef ASMFLOW_LOOP_INC
%define ASMFLOW_LOOP_INC

%define EPOLL_CTL_ADD 1
%define EPOLL_CTL_DEL 2
%define EPOLL_CTL_MOD 3

%define EPOLLIN   0x001
%define EPOLLPRI  0x002
%define EPOLLOUT  0x004
%define EPOLLERR  0x008
%define EPOLLHUP  0x010
%define EPOLLRDHUP 0x2000
%define EPOLLET   0x80000000

%define EPOLL_CLOEXEC 0x80000

; struct epoll_event is PACKED on x86-64: a 4-byte event mask immediately
; followed by the 8-byte data union, for 12 bytes total rather than the 16 a
; naive alignment would give.
%define EPOLL_EVENT_EVENTS 0
%define EPOLL_EVENT_DATA   4
%define EPOLL_EVENT_SIZE   12

; Capacity budget: 128 HTTP clients + 64 control clients + two persistent
; stdout/stderr watches for each of 256 MCP children = 704. The remaining 320
; slots cover listeners, signalfd/timers, provider sockets, and bounded growth
; without turning the table into an unbounded allocation.
%define AF_LOOP_MAX_SOURCES 1024
%define AF_LOOP_BATCH       64

; af_loop_source
;   +0   fd        -1 when the slot is free
;   +8   handler   void (*)(void *ctx, i64 fd, u64 events)
;   +16  ctx
;   +24  events    the mask currently registered
%define SRC_FD      0
%define SRC_HANDLER 8
%define SRC_CTX     16
%define SRC_EVENTS  24
%define SRC_SIZE    32

; af_loop
;   +0   epfd
;   +8   running
;   +16  stop_requested
;   +24  iterations
;   +32  sources    af_loop_source[AF_LOOP_MAX_SOURCES]
;   ...  scratch    epoll_event[AF_LOOP_BATCH]
%define LOOP_EPFD    0
%define LOOP_RUNNING 8
%define LOOP_STOP    16
%define LOOP_ITERS   24
%define LOOP_SOURCES 32
%define LOOP_EVENTS  (LOOP_SOURCES + AF_LOOP_MAX_SOURCES * SRC_SIZE)
%define LOOP_SIZE    (LOOP_EVENTS + AF_LOOP_BATCH * EPOLL_EVENT_SIZE + 8)

%endif ; ASMFLOW_LOOP_INC
