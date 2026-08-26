; AsmFlow — canonical version and build metadata.
;
; AF_VERSION_STRING is defined on the NASM command line from the repository
; `VERSION` file. Nothing else in the runtime hard-codes a version, so
; `VERSION`, `--version`, the release tag, and the changelog cannot drift
; (M1 DoD 1, M12 DoD 7).

        bits 64
        default rel

%include "asmflow.inc"

        section .rodata

af_version_text:
        db      AF_VERSION_STRING
af_version_text_len equ $ - af_version_text

af_build_target_text:
        db      "linux-x86_64"
af_build_target_text_len equ $ - af_build_target_text

%ifndef AF_BUILD_MODE
    %define AF_BUILD_MODE "unknown"
%endif
af_build_mode_text:
        db      AF_BUILD_MODE
af_build_mode_text_len equ $ - af_build_mode_text

        section .text

; ---------------------------------------------------------------------------
; af_version_str(size_t *out_len) -> const char *
;
; Ownership: the returned pointer is STATIC and outlives every caller. The
; span is not NUL-terminated; callers use the length.
; ---------------------------------------------------------------------------
        global af_version_str
af_version_str:
        test    rdi, rdi
        jz      .no_len
        mov     qword [rdi], af_version_text_len
.no_len:
        lea     rax, [af_version_text]
        ret

; ---------------------------------------------------------------------------
; af_build_target_str(size_t *out_len) -> const char *   (STATIC)
; ---------------------------------------------------------------------------
        global af_build_target_str
af_build_target_str:
        test    rdi, rdi
        jz      .no_len
        mov     qword [rdi], af_build_target_text_len
.no_len:
        lea     rax, [af_build_target_text]
        ret

; ---------------------------------------------------------------------------
; af_build_mode_str(size_t *out_len) -> const char *     (STATIC)
; ---------------------------------------------------------------------------
        global af_build_mode_str
af_build_mode_str:
        test    rdi, rdi
        jz      .no_len
        mov     qword [rdi], af_build_mode_text_len
.no_len:
        lea     rax, [af_build_mode_text]
        ret
