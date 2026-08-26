; AsmFlow — request-scoped bump arena.
;
; ARCHITECTURE.md 10: long-lived objects belong to owner modules; request-scoped
; objects live in an arena that is released as a unit when the request finishes.
; The arena exists so that the many small allocations a single HTTP request
; makes (header slices, normalised field views, attempt records) have exactly
; one lifetime and exactly one release point, which is what makes the error
; paths auditable.
;
; The hard rule that goes with it: no pointer obtained from an arena may be
; stored in global state, in the database, or in a callback context that
; outlives the request. Guard mode below exists to make a violation of that rule
; fail loudly and deterministically instead of intermittently.
;
; Layout (offsets are asserted by the ABI manifest in src/ffi):
;
;   af_arena          af_arena_chunk
;   +0  head          +0  next
;   +8  chunk_size    +8  capacity
;   +16 total_bytes   +16 used
;   +24 max_bytes     +24 map_size   (0 when the chunk came from af_alloc)
;   +32 finalized     +32 payload...
;   +40 alloc_count

        bits 64
        default rel

%include "asmflow.inc"

        extern af_alloc
        extern af_free
        extern af_add_size
        extern af_align_up
        extern af_mem_zero
        extern af_sys_mmap
        extern af_sys_mprotect
        extern af_panic

%define ARENA_HEAD        0
%define ARENA_CHUNK_SIZE  8
%define ARENA_TOTAL       16
%define ARENA_MAX         24
%define ARENA_FINALIZED   32
%define ARENA_ALLOC_COUNT 40
%define ARENA_SIZE        48

%define CHUNK_NEXT     0
%define CHUNK_CAP      8
%define CHUNK_USED     16
%define CHUNK_MAP_SIZE 24
%define CHUNK_HDR      32

%define PROT_NONE   0
%define PROT_READ   1
%define PROT_WRITE  2
%define MAP_PRIVATE   0x02
%define MAP_ANONYMOUS 0x20

%define AF_ARENA_MIN_CHUNK 4096

        section .data
; Guard mode is off by default. When on, chunks are mapped rather than
; allocated, and af_arena_finalize revokes access instead of freeing, so any
; surviving pointer faults on first touch. It is enabled by the dedicated
; use-after-finalize test and by nothing else, because retained mappings would
; otherwise accumulate across a long soak.
af_arena_guard_mode: dq 0

        section .rodata
msg_use_after_finalize: db "af_arena_alloc: arena already finalized", 0
arena_file: db __?FILE?__, 0

        section .text

; ---------------------------------------------------------------------------
; af_arena_init(af_arena *a, u64 chunk_size, u64 max_bytes) -> af_status
;
; Ownership: `a` is BORROWED storage supplied by the caller (usually embedded in
; a request object). No memory is reserved until the first allocation, so an
; arena that is never used costs nothing.
; ---------------------------------------------------------------------------
        global af_arena_init
af_arena_init:
        test    rdi, rdi
        jz      .invalid
        test    rdx, rdx
        jz      .invalid
        cmp     rsi, AF_ARENA_MIN_CHUNK
        jae     .size_ok
        mov     rsi, AF_ARENA_MIN_CHUNK
.size_ok:
        cmp     rsi, rdx
        jbe     .store
        mov     rsi, rdx
.store:
        mov     qword [rdi + ARENA_HEAD], 0
        mov     [rdi + ARENA_CHUNK_SIZE], rsi
        mov     qword [rdi + ARENA_TOTAL], 0
        mov     [rdi + ARENA_MAX], rdx
        mov     qword [rdi + ARENA_FINALIZED], 0
        mov     qword [rdi + ARENA_ALLOC_COUNT], 0
        xor     eax, eax
        ret
.invalid:
        mov     rax, AF_E_INVALID
        ret

; ---------------------------------------------------------------------------
; af_arena_alloc(af_arena *a, u64 size, u64 align) -> void * (NULL on failure)
;
; `align` must be a power of two; 0 is treated as 8. The returned pointer is
; BORROWED from the arena and is valid only until af_arena_reset or
; af_arena_finalize.
; ---------------------------------------------------------------------------
        global af_arena_alloc
af_arena_alloc:
        AF_ENTER 32
        test    rdi, rdi
        jz      .fail
        test    rsi, rsi
        jz      .fail
        mov     rbx, rdi                ; arena
        mov     r12, rsi                ; size
        mov     r13, rdx                ; align
        test    r13, r13
        jnz     .have_align
        mov     r13, 8
.have_align:
        mov     rax, [rbx + ARENA_FINALIZED]
        test    rax, rax
        jnz     .use_after_finalize

        mov     r14, [rbx + ARENA_HEAD]
        test    r14, r14
        jz      .new_chunk

.try_chunk:
        ; Align the ABSOLUTE address, not the offset within the chunk. The
        ; payload begins CHUNK_HDR bytes into a block whose own alignment is
        ; only 16, so aligning the offset would satisfy a 64-byte request with
        ; an address that is merely 16-byte aligned.
        lea     rdi, [r14 + CHUNK_HDR]
        add     rdi, [r14 + CHUNK_USED]
        mov     rsi, r13
        lea     rdx, [rsp]
        call    af_align_up
        test    rax, rax
        js      .fail
        mov     r15, [rsp]              ; aligned absolute address

        ; end = (aligned - payload_base) + size, checked
        mov     rdi, r15
        lea     rax, [r14 + CHUNK_HDR]
        sub     rdi, rax
        mov     rsi, r12
        lea     rdx, [rsp + 8]
        call    af_add_size
        test    rax, rax
        js      .fail
        mov     rax, [rsp + 8]
        cmp     rax, [r14 + CHUNK_CAP]
        ja      .new_chunk

        mov     [r14 + CHUNK_USED], rax
        inc     qword [rbx + ARENA_ALLOC_COUNT]
        mov     rax, r15
        AF_LEAVE

.new_chunk:
        ; A chunk must hold the header plus this allocation plus its alignment
        ; slack; otherwise use the configured chunk size.
        mov     rdi, r12
        mov     rsi, r13
        lea     rdx, [rsp]
        call    af_add_size
        test    rax, rax
        js      .fail
        mov     rdi, [rsp]
        mov     rsi, CHUNK_HDR
        lea     rdx, [rsp]
        call    af_add_size
        test    rax, rax
        js      .fail
        mov     rax, [rsp]              ; minimum chunk bytes
        cmp     rax, [rbx + ARENA_CHUNK_SIZE]
        jae     .chunk_bytes_ready
        mov     rax, [rbx + ARENA_CHUNK_SIZE]
.chunk_bytes_ready:
        mov     [rsp], rax

        ; In guard mode the reservation is page-granular, so round up BEFORE the
        ; ceiling check; otherwise the arena could exceed max_bytes by up to one
        ; page without the limit ever reporting it.
        mov     rax, [af_arena_guard_mode]
        test    rax, rax
        jz      .ceiling_check
        mov     rdi, [rsp]
        mov     rsi, 4096
        lea     rdx, [rsp]
        call    af_align_up
        test    rax, rax
        js      .fail

.ceiling_check:
        mov     rdi, [rbx + ARENA_TOTAL]
        mov     rsi, [rsp]
        lea     rdx, [rsp + 8]
        call    af_add_size
        test    rax, rax
        js      .fail
        mov     rax, [rsp + 8]
        cmp     rax, [rbx + ARENA_MAX]
        ja      .fail

        mov     rax, [af_arena_guard_mode]
        test    rax, rax
        jnz     .map_chunk

        mov     rdi, [rsp]
        call    af_alloc
        test    rax, rax
        jz      .fail
        mov     r14, rax
        mov     rcx, [rsp]
        sub     rcx, CHUNK_HDR
        mov     [r14 + CHUNK_CAP], rcx
        mov     qword [r14 + CHUNK_MAP_SIZE], 0
        jmp     .link_chunk

.map_chunk:
        xor     edi, edi                ; addr
        mov     rsi, [rsp]              ; length
        mov     rdx, PROT_READ | PROT_WRITE
        mov     rcx, MAP_PRIVATE | MAP_ANONYMOUS
        mov     r8, -1                  ; fd
        xor     r9d, r9d                ; offset
        call    af_sys_mmap
        cmp     rax, -4096
        ja      .fail                   ; kernel returned -errno
        mov     r14, rax
        mov     rcx, [rsp]
        mov     [r14 + CHUNK_MAP_SIZE], rcx
        sub     rcx, CHUNK_HDR
        mov     [r14 + CHUNK_CAP], rcx

.link_chunk:
        mov     rax, [rbx + ARENA_HEAD]
        mov     [r14 + CHUNK_NEXT], rax
        mov     qword [r14 + CHUNK_USED], 0
        mov     [rbx + ARENA_HEAD], r14
        mov     rax, [rsp]
        add     [rbx + ARENA_TOTAL], rax
        jmp     .try_chunk

.fail:
        xor     eax, eax
        AF_LEAVE

.use_after_finalize:
        lea     rdi, [msg_use_after_finalize]
        lea     rsi, [arena_file]
        mov     rdx, __?LINE?__
        mov     rcx, rbx
        call    af_panic

; ---------------------------------------------------------------------------
; af_arena_calloc(af_arena *a, u64 count, u64 size) -> void * (NULL on failure)
; ---------------------------------------------------------------------------
        global af_arena_calloc
af_arena_calloc:
        AF_ENTER 16
        mov     rbx, rdi
        mov     rax, rsi
        mul     rdx                     ; rdx:rax = count * size
        test    rdx, rdx
        jnz     .fail
        mov     [rsp], rax
        mov     rdi, rbx
        mov     rsi, rax
        mov     rdx, 8
        call    af_arena_alloc
        test    rax, rax
        jz      .fail
        mov     r12, rax
        mov     rdi, rax
        mov     rsi, [rsp]
        call    af_mem_zero
        mov     rax, r12
        AF_LEAVE
.fail:
        xor     eax, eax
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_arena_reset(af_arena *a) -> void
;
; Releases every chunk but leaves the arena usable. In guard mode the chunk
; mappings are revoked rather than returned to the kernel, so a stale pointer
; faults on the address it was actually handed instead of hitting a page that
; some later mapping has quietly reused.
; ---------------------------------------------------------------------------
        global af_arena_reset
af_arena_reset:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        mov     r12, [rbx + ARENA_HEAD]
.loop:
        test    r12, r12
        jz      .cleared
        mov     r13, [r12 + CHUNK_NEXT]
        mov     rax, [r12 + CHUNK_MAP_SIZE]
        test    rax, rax
        jnz     .unmap
        mov     rdi, r12
        call    af_free
        jmp     .next
.unmap:
        mov     rdi, r12
        mov     rsi, rax
        call    af_sys_mprotect_none_or_unmap
.next:
        mov     r12, r13
        jmp     .loop
.cleared:
        mov     qword [rbx + ARENA_HEAD], 0
        mov     qword [rbx + ARENA_TOTAL], 0
        mov     qword [rbx + ARENA_ALLOC_COUNT], 0
.done:
        AF_LEAVE

; Private: revoke access to a mapped chunk. The mapping is intentionally kept so
; that a stale pointer faults on the exact address it was handed, which is a far
; more useful diagnostic than a reused page that silently accepts the write.
af_sys_mprotect_none_or_unmap:
        AF_ENTER 0
        mov     rdx, PROT_NONE
        call    af_sys_mprotect
        AF_LEAVE

; ---------------------------------------------------------------------------
; af_arena_finalize(af_arena *a) -> void
;
; Releases every chunk and marks the arena permanently unusable. A later
; af_arena_alloc panics in debug builds; a later dereference of a pointer handed
; out before finalization faults when guard mode is on.
; ---------------------------------------------------------------------------
        global af_arena_finalize
af_arena_finalize:
        AF_ENTER 0
        test    rdi, rdi
        jz      .done
        mov     rbx, rdi
        call    af_arena_reset
        mov     qword [rbx + ARENA_FINALIZED], 1
.done:
        AF_LEAVE

; ---------------------------------------------------------------------------
; Diagnostics.
; ---------------------------------------------------------------------------
        global af_arena_total_bytes
af_arena_total_bytes:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + ARENA_TOTAL]
.done:
        ret

        global af_arena_alloc_count
af_arena_alloc_count:
        xor     eax, eax
        test    rdi, rdi
        jz      .done
        mov     rax, [rdi + ARENA_ALLOC_COUNT]
.done:
        ret

; af_arena_set_guard_mode(i64 on) -> void   (test-only)
        global af_arena_set_guard_mode
af_arena_set_guard_mode:
        mov     [af_arena_guard_mode], rdi
        ret

; af_arena_struct_size() -> u64
;   Lets C-side tests and the ABI manifest assert the layout without duplicating
;   the offsets.
        global af_arena_struct_size
af_arena_struct_size:
        mov     eax, ARENA_SIZE
        ret
