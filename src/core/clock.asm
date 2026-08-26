; AsmFlow — time sources.
;
; Two clocks with two different jobs, kept apart on purpose:
;
;   * CLOCK_MONOTONIC drives every duration, timeout, backoff, circuit-breaker
;     transition, and latency measurement. It cannot jump backwards when the
;     system clock is corrected, which is the failure behind runbook row 15
;     ("circuit opens for too long or too short").
;   * CLOCK_REALTIME is used only for wall-clock stamps that a human or another
;     system reads: request records, ULID timestamps, log lines.
;
; No duration in the runtime is ever computed from a realtime reading.
;
; The monotonic source can be overridden for tests so that circuit-state and
; backoff timelines are golden-comparable instead of timing-dependent
; (M7 DoD 4). The override is inert unless a test sets it.

        bits 64
        default rel

%include "asmflow.inc"

        extern af_sys_clock_gettime
        extern af_status_from_errno


        section .data
; -1 means "use the kernel". Any other value is returned verbatim, letting a
; test drive a state machine through an exact timeline.
af_clock_override_ns: dq -1

        section .text

; ---------------------------------------------------------------------------
; af_monotonic_ns(u64 *out) -> af_status
; ---------------------------------------------------------------------------
        global af_monotonic_ns
af_monotonic_ns:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi

        mov     rax, [af_clock_override_ns]
        cmp     rax, -1
        je      .from_kernel
        mov     [rbx], rax
        xor     eax, eax
        AF_LEAVE

.from_kernel:
        mov     edi, CLOCK_MONOTONIC
        lea     rsi, [rsp]
        call    af_sys_clock_gettime
        test    rax, rax
        js      .syscall_error
        mov     rax, [rsp]              ; tv_sec
        mov     rcx, NS_PER_SEC
        mul     rcx                     ; rdx:rax
        test    rdx, rdx
        jnz     .overflow
        add     rax, [rsp + 8]          ; tv_nsec
        jc      .overflow
        mov     [rbx], rax
        xor     eax, eax
        AF_LEAVE
.syscall_error:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.overflow:
        mov     rax, AF_E_OVERFLOW
        AF_LEAVE
.invalid:
        mov     rax, AF_E_INVALID
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_monotonic_ms(u64 *out) -> af_status
; ---------------------------------------------------------------------------
        global af_monotonic_ms
af_monotonic_ms:
        AF_ENTER 16
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        lea     rdi, [rsp]
        call    af_monotonic_ns
        test    rax, rax
        js      .done
        mov     rax, [rsp]
        xor     edx, edx
        mov     rcx, NS_PER_MS
        div     rcx
        mov     [rbx], rax
        xor     eax, eax
.done:
        AF_LEAVE
.invalid:
        mov     rax, AF_E_INVALID
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_realtime_ms(u64 *out) -> af_status
;
; Wall-clock milliseconds since the Unix epoch. Display and record stamps only.
; ---------------------------------------------------------------------------
        global af_realtime_ms
af_realtime_ms:
        AF_ENTER 32
        test    rdi, rdi
        jz      .invalid
        mov     rbx, rdi
        mov     edi, CLOCK_REALTIME
        lea     rsi, [rsp]
        call    af_sys_clock_gettime
        test    rax, rax
        js      .syscall_error
        mov     rax, [rsp]              ; tv_sec
        mov     rcx, 1000
        mul     rcx
        test    rdx, rdx
        jnz     .overflow
        mov     [rsp + 16], rax         ; whole seconds expressed in ms
        mov     rax, [rsp + 8]          ; tv_nsec
        xor     edx, edx
        mov     rcx, NS_PER_MS
        div     rcx
        add     rax, [rsp + 16]
        jc      .overflow
        mov     [rbx], rax
        xor     eax, eax
        AF_LEAVE
.syscall_error:
        mov     rdi, rax
        call    af_status_from_errno
        AF_LEAVE
.overflow:
        mov     rax, AF_E_OVERFLOW
        AF_LEAVE
.invalid:
        mov     rax, AF_E_INVALID
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_elapsed_ns(u64 start_ns, u64 end_ns, u64 *out) -> af_status
;
; AF_E_RANGE when `end` precedes `start`. A monotonic clock cannot run
; backwards, so that condition means the caller mixed up two different clocks or
; two different epochs, and silently returning zero would hide it.
; ---------------------------------------------------------------------------
        global af_elapsed_ns
af_elapsed_ns:
        cmp     rsi, rdi
        jb      .range
        mov     rax, rsi
        sub     rax, rdi
        mov     [rdx], rax
        xor     eax, eax
        ret
.range:
        mov     rax, AF_E_RANGE
        ret

; ---------------------------------------------------------------------------
; Test hooks. af_clock_set_override_ns(-1) restores the kernel source.
; ---------------------------------------------------------------------------
        global af_clock_set_override_ns
af_clock_set_override_ns:
        mov     [af_clock_override_ns], rdi
        ret

; af_clock_advance_ns(u64 delta) -> af_status
;   AF_E_INVALID unless an override is active, so a test cannot accidentally
;   "advance" the real clock and then wonder why nothing moved.
        global af_clock_advance_ns
af_clock_advance_ns:
        mov     rax, [af_clock_override_ns]
        cmp     rax, -1
        je      .not_overridden
        add     rax, rdi
        mov     [af_clock_override_ns], rax
        xor     eax, eax
        ret
.not_overridden:
        mov     rax, AF_E_INVALID
        ret
