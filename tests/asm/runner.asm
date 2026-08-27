; AsmFlow — assembly unit-test runner.
;
; Walks the `af_test_registry` section and runs every registered test. Three
; properties matter more than the reporting format:
;
;   * Determinism. Tests run in link order, with no clock or randomness in the
;     harness itself, so a failure reproduces from the same command
;     (TEST_STRATEGY.md 4).
;   * Per-test leak detection. The live-allocation counter is sampled before and
;     after each test; a test that returns with a block outstanding fails, so a
;     leak is attributed to the test that caused it rather than surfacing later
;     as an anonymous Valgrind summary (M2 DoD 7).
;   * Allocation-injection hygiene. The injection point is reset before each
;     test, so an allocation-failure test cannot bleed into its neighbours.
;
; Usage:
;   asmflow-tests                 run everything
;   asmflow-tests --list          print test names and exit
;   asmflow-tests --filter PREFIX run only tests whose name starts with PREFIX
;   asmflow-tests --verbose       print a line per passing test as well

        bits 64
        default rel

%include "asmflow.inc"

        extern __start_af_test_registry
        extern __stop_af_test_registry

        extern af_out_bytes
        extern af_out_cstr
        extern af_out_u64
        extern af_out_i64
        extern af_cstr_eq
        extern af_cstr_len
        extern af_cstr_starts_with
        extern af_sys_exit_group
        extern af_alloc_live_count
        extern af_alloc_reset_counters
        extern af_arena_set_guard_mode
        extern af_clock_set_override_ns
        extern af_test_run_crash
        extern af_test_run_reload_soak
        extern af_route_corpus_main
        extern af_dec_to_u64

%define AF_FD_STDOUT 1
%define AF_FD_STDERR 2

        section .data
        global af_test_failures
af_test_failures:       dq 0            ; failures in the current test
af_test_total_failures: dq 0
af_test_total_checks:   dq 0
af_test_verbose:        dq 0

        section .rodata
s_pass:      db "ok   "
s_pass_len   equ $ - s_pass
s_fail:      db "FAIL "
s_fail_len   equ $ - s_fail
s_nl:        db 10
s_indent:    db "       "
s_indent_len equ $ - s_indent
s_at:        db " at "
s_at_len     equ $ - s_at
s_colon:     db ":"
s_expected:  db "       expected "
s_expected_len equ $ - s_expected
s_actual:    db ", actual "
s_actual_len equ $ - s_actual
s_summary1:  db 10, "tests: "
s_summary1_len equ $ - s_summary1
s_summary2:  db " run, "
s_summary2_len equ $ - s_summary2
s_summary3:  db " failed, "
s_summary3_len equ $ - s_summary3
s_summary4:  db " checks", 10
s_summary4_len equ $ - s_summary4
s_leak:      db "       leaked allocations: "
s_leak_len   equ $ - s_leak
s_leak_desc: db "test leaked heap blocks", 0
s_note:      db "note   "
s_note_len   equ $ - s_note

opt_list:    db "--list", 0
opt_filter:  db "--filter", 0
opt_verbose: db "--verbose", 0
opt_crash:   db "--crash", 0
opt_reload_soak: db "--reload-soak", 0
opt_route_corpus: db "--routing-corpus", 0

        section .text

; ---------------------------------------------------------------------------
; main(int argc, char **argv) -> int
; ---------------------------------------------------------------------------
; Locals:
;   [rsp +  0]  live allocation count before the current test
;   [rsp +  8]  live allocation count after the current test
;   [rsp + 16]  filter prefix (NULL = run everything)
;   [rsp + 24]  list-only flag
        global main
main:
        AF_ENTER 32
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], 0
        mov     rbx, rdi                ; argc
        mov     r12, rsi                ; argv
        mov     r13, 1                  ; index

.args:
        cmp     r13, rbx
        jae     .args_done
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_list]
        call    af_cstr_eq
        test    rax, rax
        jnz     .set_list
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_verbose]
        call    af_cstr_eq
        test    rax, rax
        jnz     .set_verbose
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_filter]
        call    af_cstr_eq
        test    rax, rax
        jnz     .set_filter
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_crash]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_crash
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_reload_soak]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_reload_soak
        mov     rdi, [r12 + r13 * 8]
        lea     rsi, [opt_route_corpus]
        call    af_cstr_eq
        test    rax, rax
        jnz     .do_route_corpus
        inc     r13
        jmp     .args

; --routing-corpus PATH runs the routing scenarios in PATH and prints what the
; selector decided, for tests/test_routing_parity.py to compare against the
; Python oracle. Kept out of the registry because it takes an argument and
; produces data rather than a verdict.
.do_route_corpus:
        inc     r13
        cmp     r13, rbx
        jae     .args_done
        mov     rdi, [r12 + r13 * 8]
        call    af_route_corpus_main
        movsxd  rdi, eax
        call    af_sys_exit_group
        ud2

; --reload-soak N runs the configuration reload soak and never returns. It is
; kept out of the registry because it takes long enough to spoil the ordinary
; feedback loop; the milestone gate invokes it explicitly.
.do_reload_soak:
        inc     r13
        cmp     r13, rbx
        jae     .args_done
        mov     rdi, [r12 + r13 * 8]
        call    af_cstr_len
        mov     rdx, rax
        mov     rdi, [r12 + r13 * 8]
        mov     rsi, rdx
        lea     rdx, [rsp]
        call    af_dec_to_u64
        test    rax, rax
        js      .args_done
        mov     rdi, [rsp]
        call    af_test_run_reload_soak
        ud2

; --crash N runs one deliberately fatal scenario and never returns. It is kept
; out of the registry so a normal run cannot stumble into it.
.do_crash:
        inc     r13
        cmp     r13, rbx
        jae     .args_done
        mov     rdi, [r12 + r13 * 8]
        call    af_cstr_len
        mov     rdx, rax
        mov     rdi, [r12 + r13 * 8]
        mov     rsi, rdx
        lea     rdx, [rsp]
        call    af_dec_to_u64
        test    rax, rax
        js      .args_done
        mov     rdi, [rsp]
        call    af_test_run_crash
        ud2
.set_list:
        mov     qword [rsp + 24], 1
        inc     r13
        jmp     .args
.set_verbose:
        mov     qword [af_test_verbose], 1
        inc     r13
        jmp     .args
.set_filter:
        inc     r13
        cmp     r13, rbx
        jae     .args_done
        mov     rax, [r12 + r13 * 8]
        mov     [rsp + 16], rax
        inc     r13
        jmp     .args

.args_done:
        ; Guard mode is opt-in per test; make sure a previous process image or a
        ; test that failed mid-way cannot leave it enabled for the whole run.
        xor     edi, edi
        call    af_arena_set_guard_mode

        lea     rbx, [__start_af_test_registry]
        lea     r12, [__stop_af_test_registry]
        xor     r13, r13                ; tests run

.loop:
        cmp     rbx, r12
        jae     .finish

        ; Decode the entry. Both fields are 32-bit offsets relative to their own
        ; address, so the table needs no relocation at load time.
        movsxd  rax, dword [rbx]
        lea     r14, [rbx + rax]        ; test name
        movsxd  rax, dword [rbx + 4]
        lea     r15, [rbx + rax + 4]    ; test entry point

        ; Apply the name filter.
        mov     rdi, r14
        mov     rsi, [rsp + 16]         ; saved filter
        test    rsi, rsi
        jz      .selected
        call    af_cstr_starts_with
        test    rax, rax
        jz      .skip
.selected:
        cmp     qword [rsp + 24], 0
        jne     .just_list

        ; Fresh allocator state for every test.
        call    af_alloc_reset_counters
        call    af_alloc_live_count
        mov     [rsp], rax              ; live blocks before
        mov     qword [af_test_failures], 0

        call    r15                     ; the test body

        ; Restore the shared test-only switches. A test that fails partway
        ; through must not change how the next test behaves.
        xor     edi, edi
        call    af_arena_set_guard_mode
        mov     rdi, -1
        call    af_clock_set_override_ns

        call    af_alloc_live_count
        mov     [rsp + 8], rax
        mov     rcx, [rsp]
        cmp     rax, rcx
        je      .no_leak
        sub     rax, rcx
        mov     rdi, rax
        call    af_report_leak
.no_leak:
        inc     r13
        mov     rax, [af_test_failures]
        test    rax, rax
        jnz     .report_fail
        mov     rax, [af_test_verbose]
        test    rax, rax
        jz      .next
        lea     rsi, [s_pass]
        mov     rdx, s_pass_len
        mov     edi, AF_FD_STDOUT
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, r14
        call    af_out_cstr
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_nl]
        mov     rdx, 1
        call    af_out_bytes
        jmp     .next

.report_fail:
        add     [af_test_total_failures], rax
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_fail]
        mov     rdx, s_fail_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, r14
        call    af_out_cstr
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_nl]
        mov     rdx, 1
        call    af_out_bytes
        jmp     .next

.just_list:
        mov     edi, AF_FD_STDOUT
        mov     rsi, r14
        call    af_out_cstr
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_nl]
        mov     rdx, 1
        call    af_out_bytes
        inc     r13
.skip:
.next:
        add     rbx, 8
        jmp     .loop

.finish:
        cmp     qword [rsp + 24], 0
        jne     .exit_ok

        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_summary1]
        mov     rdx, s_summary1_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, r13
        call    af_out_u64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_summary2]
        mov     rdx, s_summary2_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, [af_test_total_failures]
        call    af_out_u64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_summary3]
        mov     rdx, s_summary3_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, [af_test_total_checks]
        call    af_out_u64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_summary4]
        mov     rdx, s_summary4_len
        call    af_out_bytes

        mov     rax, [af_test_total_failures]
        test    rax, rax
        jnz     .exit_fail
.exit_ok:
        xor     edi, edi
        call    af_sys_exit_group
        ud2
.exit_fail:
        mov     edi, 1
        call    af_sys_exit_group
        ud2

; ---------------------------------------------------------------------------
; af_report_leak(u64 blocks) -> void
; ---------------------------------------------------------------------------
af_report_leak:
        AF_ENTER 0
        mov     rbx, rdi
        inc     qword [af_test_failures]
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_leak]
        mov     rdx, s_leak_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, rbx
        call    af_out_u64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_nl]
        mov     rdx, 1
        call    af_out_bytes
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_test_fail_header(const char *desc, const char *file, u64 line) -> void
;
; Private: prints "       <desc> at <file>:<line>".
; ---------------------------------------------------------------------------
af_test_fail_header:
        AF_ENTER 0
        mov     rbx, rdi
        mov     r12, rsi
        mov     r13, rdx
        inc     qword [af_test_failures]

        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_indent]
        mov     rdx, s_indent_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, rbx
        call    af_out_cstr
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_at]
        mov     rdx, s_at_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, r12
        call    af_out_cstr
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_colon]
        mov     rdx, 1
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, r13
        call    af_out_u64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_nl]
        mov     rdx, 1
        call    af_out_bytes
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_test_check_eq(i64 actual, i64 expected, const char *desc,
;                  const char *file, u64 line) -> void
; ---------------------------------------------------------------------------
        global af_test_check_eq
af_test_check_eq:
        AF_ENTER 0
        inc     qword [af_test_total_checks]
        mov     rbx, rdi                ; actual
        mov     r12, rsi                ; expected
        cmp     rbx, r12
        je      .done
        mov     rdi, rdx
        mov     rsi, rcx
        mov     rdx, r8
        call    af_test_fail_header
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_expected]
        mov     rdx, s_expected_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, r12
        call    af_out_i64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_actual]
        mov     rdx, s_actual_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, rbx
        call    af_out_i64
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_nl]
        mov     rdx, 1
        call    af_out_bytes
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_test_check_ne(i64 actual, i64 unexpected, const char *desc,
;                  const char *file, u64 line) -> void
; ---------------------------------------------------------------------------
        global af_test_check_ne
af_test_check_ne:
        AF_ENTER 0
        inc     qword [af_test_total_checks]
        cmp     rdi, rsi
        jne     .done
        mov     rdi, rdx
        mov     rsi, rcx
        mov     rdx, r8
        call    af_test_fail_header
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_test_check_true(i64 value, const char *desc, const char *file, u64 line)
;   -> void
; ---------------------------------------------------------------------------
        global af_test_check_true
af_test_check_true:
        AF_ENTER 0
        inc     qword [af_test_total_checks]
        test    rdi, rdi
        jnz     .done
        mov     rdi, rsi
        mov     rsi, rdx
        mov     rdx, rcx
        call    af_test_fail_header
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_test_check_mem_eq(const void *a, const void *b, u64 n, const char *desc,
;                      const char *file, u64 line) -> void
; ---------------------------------------------------------------------------
        global af_test_check_mem_eq
af_test_check_mem_eq:
        AF_ENTER 0
        inc     qword [af_test_total_checks]
        mov     rbx, rcx                ; desc
        mov     r12, r8                 ; file
        mov     r13, r9                 ; line
        xor     ecx, ecx
.loop:
        cmp     rcx, rdx
        jae     .done
        mov     al, [rdi + rcx]
        cmp     al, [rsi + rcx]
        jne     .differ
        inc     rcx
        jmp     .loop
.differ:
        mov     rdi, rbx
        mov     rsi, r12
        mov     rdx, r13
        call    af_test_fail_header
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_test_note(const char *text) -> void
; ---------------------------------------------------------------------------
        global af_test_note
af_test_note:
        AF_ENTER 0
        mov     rbx, rdi
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_note]
        mov     rdx, s_note_len
        call    af_out_bytes
        mov     edi, AF_FD_STDOUT
        mov     rsi, rbx
        call    af_out_cstr
        mov     edi, AF_FD_STDOUT
        lea     rsi, [s_nl]
        mov     rdx, 1
        call    af_out_bytes
        AF_LEAVE
