#!/usr/bin/env python3
"""Static callee-saved register audit for every exported AsmFlow function.

HARNESS.md M2 DoD 1 asks that *every* exported function pass an ABI probe, and
DoD 3 asks for zero callee-saved register corruption. Calling every export with
synthetic arguments is not a way to establish that: most of them take pointers
to real objects, and the ones that do not are the least likely to be wrong.

So the dynamic probe in tests/asm/test_abi.asm covers representative functions,
and this script covers all of them structurally. It disassembles the binary and,
for each `af_*` symbol, checks the property that actually makes the ABI hold:

  * if the function body writes rbx, rbp, r12, r13, r14, or r15, it must open
    with the exact AF_ENTER prologue and close every return path with the
    AF_LEAVE epilogue;
  * a function that writes none of them is a conforming leaf and needs no frame.

That is the invariant AF_ENTER/AF_LEAVE exist to guarantee, so an author who
hand-rolls a prologue, forgets one push, or adds an early `ret` that skips the
epilogue fails here rather than in a distant module weeks later.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

CALLEE_SAVED = {"rbx", "rbp", "r12", "r13", "r14", "r15"}

# Deliberately non-conforming test fixtures. af_abi_bad_callee exists precisely
# to prove the dynamic probe detects register corruption; a probe that cannot
# fail is not a probe. Nothing outside tests/asm belongs on this list.
EXEMPT = {
    "af_abi_bad_callee": "test fixture: intentionally clobbers callee-saved registers",
}
# 32-bit and 16/8-bit aliases write the same architectural registers.
ALIASES = {
    "ebx": "rbx", "bx": "rbx", "bl": "rbx", "bh": "rbx",
    "ebp": "rbp", "bp": "rbp", "bpl": "rbp",
    "r12d": "r12", "r12w": "r12", "r12b": "r12",
    "r13d": "r13", "r13w": "r13", "r13b": "r13",
    "r14d": "r14", "r14w": "r14", "r14b": "r14",
    "r15d": "r15", "r15w": "r15", "r15b": "r15",
}

EXPECTED_PROLOGUE = [
    ("push", "rbp"),
    ("mov", "rbp,rsp"),
    ("push", "rbx"),
    ("push", "r12"),
    ("push", "r13"),
    ("push", "r14"),
    ("push", "r15"),
]

# Instructions whose first operand is written.
WRITE_FIRST_OPERAND = {
    "mov", "movzx", "movsx", "movsxd", "lea", "add", "sub", "and", "or", "xor",
    "adc", "sbb", "inc", "dec", "neg", "not", "shl", "shr", "sar", "rol", "ror",
    "imul", "xchg", "sete", "setne", "seta", "setae", "setb", "setbe", "setg",
    "setge", "setl", "setle", "setz", "setnz", "cmov", "bswap", "pop",
}


class AuditError(RuntimeError):
    pass


def canonical(reg: str) -> str | None:
    reg = reg.strip().lstrip("%")
    reg = ALIASES.get(reg, reg)
    return reg if reg in CALLEE_SAVED else None


def disassemble(binary: Path) -> str:
    result = subprocess.run(
        ["objdump", "-d", "--no-show-raw-insn", "-M", "intel", str(binary)],
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        raise AuditError(f"objdump failed: {result.stderr.strip()}")
    return result.stdout


SYMBOL_RE = re.compile(r"^[0-9a-f]+ <([^>]+)>:$")
INSN_RE = re.compile(r"^\s+[0-9a-f]+:\s+(\S+)\s*(.*)$")

ASM_GLOBAL_RE = re.compile(r"^\s*global\s+(af_[A-Za-z0-9_]+)\s*$", re.MULTILINE)
# A C function definition at file scope: an optional return type, then the name,
# then an opening parenthesis. Declarations end in `;` and are filtered out.
C_FUNC_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_ \*]*\b(af_[A-Za-z0-9_]+)\s*\(", re.MULTILINE)


def _nm(binary: Path) -> list[list[str]]:
    result = subprocess.run(
        ["nm", "--defined-only", str(binary)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        raise AuditError(f"nm failed: {result.stderr.strip()}")
    return [line.split() for line in result.stdout.splitlines()]


def all_defined_symbols(binary: Path) -> set[str]:
    """Every defined `af_*` symbol, of any type.

    Used only to confirm that an assembly export actually reached the link; a
    `global` on a data object is a legitimate export and must not be mistaken
    for a missing function.
    """
    return {
        parts[2]
        for parts in _nm(binary)
        if len(parts) >= 3 and parts[2].startswith("af_")
    }


def text_symbols(binary: Path) -> set[str]:
    """Every `af_*` symbol that lives in a text section of the binary.

    Using the symbol type rather than a name pattern keeps data labels such as
    af_version_text and af_alloc_live_blocks out of a function audit.
    """
    names: set[str] = set()
    for parts in _nm(binary):
        if len(parts) < 3 or parts[1] not in {"T", "t"}:
            continue
        name = parts[2]
        if not name.startswith("af_"):
            continue
        # `function.label` is a NASM local label, folded into its parent by
        # parse_functions; it is not a separate entry point.
        if "." in name:
            continue
        names.add(name)
    return names


def c_defined_symbols() -> set[str]:
    """Functions the C compiler emits.

    The audit applies to assembly only: a C prologue comes from the compiler,
    which is not the thing under test, and legitimately differs from AF_ENTER.
    """
    names: set[str] = set()
    # `tests/ffi` is scanned for the same reason `src/ffi` is: the test binary
    # links a C harness too, and a compiler-emitted prologue there is no more
    # under test than one here.
    for pattern in ("src/**/*.c", "tests/ffi/*.c"):
        for path in ROOT.glob(pattern):
            names.update(C_FUNC_RE.findall(path.read_text(encoding="utf-8")))
    return names


def assembly_exports() -> set[str]:
    names: set[str] = set()
    for pattern in ("src/**/*.asm", "tests/asm/*.asm"):
        for path in ROOT.glob(pattern):
            names.update(ASM_GLOBAL_RE.findall(path.read_text(encoding="utf-8")))
    return names


def parse_functions(disasm: str) -> dict[str, list[tuple[str, str]]]:
    """Group instructions by function entry point.

    NASM emits its local labels (`.loop`, `.done`) into the symbol table as
    `function.label`, and objdump starts a new block at each one. Those are
    continuations of the function that precedes them, not entry points, so they
    are folded back in; otherwise every loop body would look like a function
    with no prologue.
    """
    functions: dict[str, list[tuple[str, str]]] = {}
    current: str | None = None
    for line in disasm.splitlines():
        symbol = SYMBOL_RE.match(line)
        if symbol:
            name = symbol.group(1)
            if "." in name and current is not None and name.startswith(current + "."):
                continue  # local label: keep appending to the current function
            current = name
            functions.setdefault(current, [])
            continue
        if current is None:
            continue
        insn = INSN_RE.match(line)
        if insn:
            functions[current].append((insn.group(1), insn.group(2).strip()))
    return functions


def written_callee_saved(body: list[tuple[str, str]], skip: int) -> set[str]:
    """Callee-saved registers written after the prologue."""
    written: set[str] = set()
    for mnemonic, operands in body[skip:]:
        base = mnemonic.split(".")[0]
        if base.startswith("cmov"):
            base = "cmov"
        if base not in WRITE_FIRST_OPERAND:
            continue
        if not operands:
            continue
        first = operands.split(",")[0].strip()
        # A memory destination such as `[rbp-0x8]` writes memory, not a register.
        if "[" in first:
            continue
        reg = canonical(first)
        if reg:
            written.add(reg)
    return written


def has_expected_prologue(body: list[tuple[str, str]]) -> bool:
    if len(body) < len(EXPECTED_PROLOGUE):
        return False
    for index, (mnemonic, operand) in enumerate(EXPECTED_PROLOGUE):
        actual_mnemonic, actual_operands = body[index]
        if actual_mnemonic != mnemonic:
            return False
        normalised = actual_operands.replace(" ", "")
        if normalised != operand:
            return False
    return True


def epilogue_is_complete(body: list[tuple[str, str]]) -> bool:
    """Every `ret` must be preceded by the five pops and the `pop rbp`.

    Checked by walking backwards from each `ret` over the six pops, which also
    catches an early return added later that skips the restore sequence.
    """
    expected = ["rbp", "rbx", "r12", "r13", "r14", "r15"]
    for index, (mnemonic, _) in enumerate(body):
        if mnemonic != "ret":
            continue
        pops: list[str] = []
        cursor = index - 1
        while cursor >= 0 and len(pops) < 6:
            m, operands = body[cursor]
            if m != "pop":
                break
            pops.append(operands.strip())
            cursor -= 1
        if sorted(pops) != sorted(expected):
            return False
    return True


def audit(binary: Path) -> tuple[int, int, int]:
    functions = parse_functions(disassemble(binary))
    in_binary = text_symbols(binary)
    audit_set = in_binary - c_defined_symbols() - set(EXEMPT)
    problems: list[str] = []
    framed = 0
    leaves = 0
    seen: set[str] = set()

    for name, body in sorted(functions.items()):
        if name not in audit_set:
            continue
        if not body:
            continue
        seen.add(name)

        if has_expected_prologue(body):
            framed += 1
            if not epilogue_is_complete(body):
                problems.append(
                    f"{name}: has the AF_ENTER prologue but at least one `ret` "
                    f"does not restore every callee-saved register"
                )
            continue

        written = written_callee_saved(body, skip=0)
        if written:
            problems.append(
                f"{name}: writes {', '.join(sorted(written))} without the "
                f"AF_ENTER prologue"
            )
        else:
            leaves += 1

    # An assembly export that never reached the binary means a module dropped
    # out of the link and the audit silently stopped covering it, which is how
    # "every export is checked" quietly becomes false.
    unlinked = sorted(assembly_exports() - all_defined_symbols(binary))
    problems.extend(
        f"{name}: exported from assembly but absent from {binary.name}; "
        f"the audit would not have covered it"
        for name in unlinked
    )
    uncovered = sorted(audit_set - seen)
    problems.extend(
        f"{name}: present in {binary.name} but produced no disassembly to audit"
        for name in uncovered
    )

    if problems:
        for problem in problems:
            print(f"[fail] {problem}", file=sys.stderr)
        raise AuditError(f"{len(problems)} function(s) violate the callee-saved contract")

    return framed, leaves, len(EXEMPT)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    args = parser.parse_args()
    binary = Path(args.binary)
    if not binary.is_file():
        print(f"[fail] no such binary: {binary}", file=sys.stderr)
        return 1
    try:
        framed, leaves, exempt = audit(binary)
    except AuditError as exc:
        print(f"[fail] {exc}", file=sys.stderr)
        return 1
    print(
        f"[ok] callee-saved contract: {framed} framed function(s), "
        f"{leaves} conforming leaf function(s), {exempt} documented exemption(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
