# AsmFlow build and verification entry points.
#
# CI and local development must call the same targets (AGENTS.md, M1 DoD 5).
# Every milestone gate in HARNESS.md maps onto a `gate-mN` target here so that
# "run the phase gate" is one command with one exit code.

PYTHON  ?= python3
NASM    ?= nasm
CC      ?= gcc
PKGCONF ?= pkg-config

PACKAGE_NAME := AsmFlow
VERSION      := $(shell cat VERSION)

BUILD_DIR ?= build
DEBUG_DIR   := $(BUILD_DIR)/debug
RELEASE_DIR := $(BUILD_DIR)/release

# ---------------------------------------------------------------------------
# Source groups.
#
# The split is a linkage-level enforcement of the module boundaries in
# ARCHITECTURE.md 4: asmflow-tui simply cannot call storage or provider code,
# because those objects are never handed to its link line (invariant 14).
# ---------------------------------------------------------------------------
DAEMON_ENTRY := src/platform/linux_x86_64/entry_daemon.asm
DAEMON_ONLY  := $(DAEMON_ENTRY) src/platform/linux_x86_64/daemon.asm
TUI_ENTRY    := src/tui/entry_tui.asm

SRC_PLATFORM := $(filter-out $(DAEMON_ONLY),$(wildcard src/platform/linux_x86_64/*.asm))
SRC_CORE     := $(wildcard src/core/*.asm)
SRC_MEMORY   := $(wildcard src/memory/*.asm)
SRC_JSON     := $(wildcard src/json/*.asm)
SRC_CONFIG   := $(wildcard src/config/*.asm)
SRC_HTTP     := $(wildcard src/http/*.asm)
SRC_PROVIDER := $(wildcard src/providers/*.asm)
SRC_ROUTING  := $(wildcard src/routing/*.asm)
SRC_MCP      := $(wildcard src/mcp/*.asm)
SRC_STORAGE  := $(wildcard src/storage/*.asm)
SRC_CONTROL  := $(wildcard src/control/*.asm)
SRC_TUI      := $(filter-out $(TUI_ENTRY),$(wildcard src/tui/*.asm))
# The Jansson adapter is linked by anything that parses JSON, which is both
# binaries. The SQLite manifest belongs to the daemon alone, because the console
# must not link libsqlite3 at all (AGENTS.md invariant 14). The ABI probe exists
# only for the test harness.
SRC_FFI_SHARED := src/ffi/json_shim.c
SRC_FFI_DAEMON := src/ffi/sqlite_shim.c src/ffi/llhttp_shim.c
SRC_FFI_TEST   := src/ffi/abi_probe.c
SRC_FFI_C      := $(SRC_FFI_SHARED) $(SRC_FFI_DAEMON) $(SRC_FFI_TEST)

# Assembly test sources. The unit-test binary links every runtime module except
# the two entry points, so a test may call any exported function directly.
SRC_TEST_ASM := $(wildcard tests/asm/*.asm)

# Shared by both binaries. Deliberately small: configuration loading is NOT
# here, because the console reads state through the control socket and has no
# business parsing the daemon's configuration file.
SRC_SHARED := $(SRC_PLATFORM) $(SRC_CORE) $(SRC_MEMORY) $(SRC_JSON) \
              $(SRC_FFI_SHARED)

SRC_DAEMON := $(DAEMON_ONLY) $(SRC_SHARED) $(SRC_CONFIG) $(SRC_HTTP) \
              $(SRC_PROVIDER) $(SRC_ROUTING) $(SRC_MCP) $(SRC_STORAGE) \
              $(SRC_CONTROL) $(SRC_FFI_DAEMON)

# The console links the control-plane *client* half plus shared primitives.
SRC_TUI_BIN := $(TUI_ENTRY) $(SRC_TUI) $(SRC_SHARED) \
               $(filter %/control_client.asm %/control_frame.asm,$(SRC_CONTROL))

SRC_TESTS := $(SRC_TEST_ASM) $(SRC_SHARED) $(SRC_CONFIG) $(SRC_HTTP) \
             $(SRC_PROVIDER) $(SRC_ROUTING) $(SRC_MCP) $(SRC_STORAGE) \
             $(SRC_CONTROL) $(SRC_TUI) src/platform/linux_x86_64/daemon.asm \
             $(SRC_FFI_DAEMON) $(SRC_FFI_TEST)

# ---------------------------------------------------------------------------
# Toolchain flags.
# ---------------------------------------------------------------------------
# -w+all turns on every NASM diagnostic, then the three relocation warnings are
# turned back off. `default rel` produces a cross-section PC-relative relocation
# for every .rodata reference, and a table of pointers in .data.rel.ro produces
# a 64-bit absolute one that the loader rewrites and RELRO then makes read-only
# again; both are exactly what a position-independent executable is supposed to
# contain. Everything else is promoted to an error so a new warning cannot
# accumulate unnoticed.
NASM_COMMON := -f elf64 -I include/ -w+all \
               -w-reloc-rel-dword -w-reloc-abs-dword -w-reloc-abs-qword \
               -w+error -DAF_VERSION_STRING='"$(VERSION)"'
NASM_DEBUG   := $(NASM_COMMON) -g -F dwarf -DAF_BUILD_MODE='"debug"' -DAF_DEBUG=1
NASM_RELEASE := $(NASM_COMMON) -DAF_BUILD_MODE='"release"'

# -fno-omit-frame-pointer keeps __builtin_frame_address usable in the ABI probe
# and makes a backtrace from a crashed release binary meaningful.
CFLAGS_COMMON  := -std=c11 -Wall -Wextra -Werror -fPIC -Iinclude \
                  -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
                  -fno-omit-frame-pointer
CFLAGS_DEBUG   := $(CFLAGS_COMMON) -O1 -g3
CFLAGS_RELEASE := $(CFLAGS_COMMON) -O2

# PIE plus a non-executable stack, full RELRO, and immediate binding.
# M1 DoD 4 asserts zero linker warnings, zero executable stack, and zero text
# relocations; these flags plus `default rel` in every .asm are what make that
# hold.
LDFLAGS_SEC := -pie -Wl,-z,noexecstack -Wl,-z,relro,-z,now -Wl,--fatal-warnings
LDFLAGS_MAP  = -Wl,-Map,$(@).map

DAEMON_PKGS := libcurl sqlite3 jansson
DAEMON_LIBS := $(shell $(PKGCONF) --libs $(DAEMON_PKGS) 2>/dev/null) -lllhttp
DAEMON_CPPFLAGS := $(shell $(PKGCONF) --cflags $(DAEMON_PKGS) 2>/dev/null)

# The console needs JSON for the NDJSON control protocol and ncursesw for the
# screen. It must not appear here with libcurl or libsqlite3.
TUI_PKGS := jansson ncursesw
TUI_LIBS := $(shell $(PKGCONF) --libs $(TUI_PKGS) 2>/dev/null)

TEST_LIBS := $(DAEMON_LIBS) $(TUI_LIBS)

# ---------------------------------------------------------------------------
# Object mapping: build/<mode>/obj/<source path>.o
# ---------------------------------------------------------------------------
obj_of = $(patsubst %.asm,$(1)/obj/%.o,$(patsubst %.c,$(1)/obj/%.o,$(2)))

DAEMON_OBJ_DEBUG   := $(call obj_of,$(DEBUG_DIR),$(SRC_DAEMON))
DAEMON_OBJ_RELEASE := $(call obj_of,$(RELEASE_DIR),$(SRC_DAEMON))
TUI_OBJ_DEBUG      := $(call obj_of,$(DEBUG_DIR),$(SRC_TUI_BIN))
TUI_OBJ_RELEASE    := $(call obj_of,$(RELEASE_DIR),$(SRC_TUI_BIN))
TEST_OBJ_DEBUG     := $(call obj_of,$(DEBUG_DIR),$(SRC_TESTS))

.PHONY: help check check-buildless test validate package clean \
        build build-debug build-release build-tests \
        test-unit test-abi test-alloc-failure test-crash \
        valgrind-unit gdb-abi-smoke abi-audit \
        test-config test-config-parity test-config-reload-soak \
        valgrind-config \
        test-migrations test-storage test-control test-control-fd-soak \
        valgrind-storage valgrind-http \
        test-http test-http-contract test-http-limits test-http-smuggling \
        test-http-fragments test-http-faults test-http-soak \
        gate-m0 gate-m1 gate-m2 gate-m3 gate-m4 gate-m5 \
        toolchain-versions

help:
	@printf '%s\n' \
	  'AsmFlow $(VERSION)' \
	  '' \
	  'Repository gates:' \
	  '  make check          Validate repository and run Python contract tests' \
	  '  make validate       Validate files, JSON, examples, and policies' \
	  '  make test           Run Python contract/oracle tests' \
	  '  make check-buildless  Run `check` as a machine with no build sees it' \
	  '' \
	  'Build:' \
	  '  make build          Debug and release binaries' \
	  '  make build-debug    Debug binaries with DWARF symbols' \
	  '  make build-release  Release binaries (PIE, stripped, separate symbols)' \
	  '  make build-tests    Assembly unit-test binary (debug only)' \
	  '  make clean          Remove generated output' \
	  '' \
	  'Tests:' \
	  '  make test-unit      Assembly unit tests' \
	  '  make test-abi       ABI conformance subset' \
	  '  make test-crash     Scenarios that must terminate the process' \
	  '  make valgrind-unit  Unit tests under Valgrind memcheck' \
	  '  make abi-audit      Static callee-saved register audit' \
	  '  make gdb-abi-smoke  Stop inside the alignment probe under GDB' \
	  '' \
	  'Milestone gates:' \
	  '  make gate-m0        Specification and contract scaffold' \
	  '  make gate-m1        Toolchain and build foundation' \
	  '  make gate-m2        ABI, memory, and core primitives' \
	  '  make gate-m3        JSON, configuration, and secret references' \
	  '  make gate-m4        SQLite, migrations, and the control plane' \
	  '  make gate-m5        Gateway HTTP listener and contract' \
	  '' \
	  'Packaging:' \
	  '  make package        Create a source archive under dist/'

toolchain-versions:
	@$(NASM) -v
	@$(CC) --version | head -1
	@ld --version | head -1
	@$(PKGCONF) --modversion $(DAEMON_PKGS) ncursesw | tr '\n' ' '; echo

# ---------------------------------------------------------------------------
# Compilation rules.
#
# VERSION is a prerequisite so that bumping it re-stamps every binary and
# `--version` can never report a stale value (M1 DoD 1).
# ---------------------------------------------------------------------------
$(DEBUG_DIR)/obj/%.o: %.asm $(wildcard include/*.inc) VERSION
	@mkdir -p $(dir $@)
	$(NASM) $(NASM_DEBUG) -o $@ $<

$(RELEASE_DIR)/obj/%.o: %.asm $(wildcard include/*.inc) VERSION
	@mkdir -p $(dir $@)
	$(NASM) $(NASM_RELEASE) -o $@ $<

$(DEBUG_DIR)/obj/%.o: %.c $(wildcard include/*.h) VERSION
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_DEBUG) $(DAEMON_CPPFLAGS) -c -o $@ $<

$(RELEASE_DIR)/obj/%.o: %.c $(wildcard include/*.h) VERSION
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_RELEASE) $(DAEMON_CPPFLAGS) -c -o $@ $<

# ---------------------------------------------------------------------------
# Link rules.
# ---------------------------------------------------------------------------
$(DEBUG_DIR)/asmflowd: $(DAEMON_OBJ_DEBUG)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS_SEC) $(LDFLAGS_MAP) -o $@ $^ $(DAEMON_LIBS)

$(DEBUG_DIR)/asmflow-tui: $(TUI_OBJ_DEBUG)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS_SEC) $(LDFLAGS_MAP) -o $@ $^ $(TUI_LIBS)

$(RELEASE_DIR)/asmflowd: $(DAEMON_OBJ_RELEASE)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS_SEC) $(LDFLAGS_MAP) -o $@.unstripped $^ $(DAEMON_LIBS)
	objcopy --only-keep-debug $@.unstripped $@.debug
	objcopy --strip-all --add-gnu-debuglink=$@.debug $@.unstripped $@
	chmod +x $@

$(RELEASE_DIR)/asmflow-tui: $(TUI_OBJ_RELEASE)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS_SEC) $(LDFLAGS_MAP) -o $@.unstripped $^ $(TUI_LIBS)
	objcopy --only-keep-debug $@.unstripped $@.debug
	objcopy --strip-all --add-gnu-debuglink=$@.debug $@.unstripped $@
	chmod +x $@

# The unit-test binary is debug-only: it depends on assertions, arena guard
# mode, and the clock override, none of which exist in a release build.
$(DEBUG_DIR)/asmflow-tests: $(TEST_OBJ_DEBUG)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS_SEC) $(LDFLAGS_MAP) -o $@ $^ $(TEST_LIBS)

build-tests: $(DEBUG_DIR)/asmflow-tests
build-debug: $(DEBUG_DIR)/asmflowd $(DEBUG_DIR)/asmflow-tui
build-release: $(RELEASE_DIR)/asmflowd $(RELEASE_DIR)/asmflow-tui
build: build-debug build-release

# ---------------------------------------------------------------------------
# Repository gates.
# ---------------------------------------------------------------------------
test:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

validate:
	$(PYTHON) scripts/validate_repo.py

check: validate test

# The M0 gate as a machine that has never built AsmFlow sees it.
#
# `make check` must pass with only Python and Make present (HARNESS.md M0),
# which means every suite needing a binary has to skip rather than error. On a
# developer machine that has built, plain `make check` cannot show that: the
# binaries are there. Pointing BUILD_DIR at a path that holds no build
# reproduces the CI condition locally, which is where it should have been
# caught the first time.
check-buildless:
	BUILD_DIR=$(BUILD_DIR)/none-of-this-exists $(MAKE) check

gate-m0: check

# ---------------------------------------------------------------------------
# M1 gate: toolchain and build foundation.
# ---------------------------------------------------------------------------
gate-m1: build
	$(PYTHON) scripts/gate_m1.py --build-dir $(BUILD_DIR) --version "$(VERSION)"

# ---------------------------------------------------------------------------
# M2 targets: ABI, memory, and core primitives.
# ---------------------------------------------------------------------------
test-unit: build-tests
	$(DEBUG_DIR)/asmflow-tests

test-abi: build-tests
	$(DEBUG_DIR)/asmflow-tests --filter abi/ --verbose

test-alloc-failure: build-tests
	$(DEBUG_DIR)/asmflow-tests --filter alloc/ --verbose

test-crash: build-tests
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_asm_crash

# Valgrind must report zero invalid accesses and zero definitely-lost bytes
# (M2 DoD 7). --error-exitcode makes that a build failure rather than a line of
# output somebody has to read.
valgrind-unit: build-tests
	valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite \
	  --errors-for-leak-kinds=definite --track-origins=yes \
	  --error-exitcode=99 \
	  $(DEBUG_DIR)/asmflow-tests

# A live debugger path, not only a pass/fail number: stop inside the alignment
# probe and print the residue of the caller's rsp.
gdb-abi-smoke: build-tests
	gdb -batch -nx \
	  -ex 'set confirm off' \
	  -ex 'break af_abi_probe_alignment' \
	  -ex 'run --filter abi/enter_aligns' \
	  -ex 'printf "caller rsp residue = %d\n", (((unsigned long)$$rsp + 8) % 16)' \
	  -ex 'kill' \
	  --args $(DEBUG_DIR)/asmflow-tests --filter abi/enter_aligns

abi-audit: build-tests
	$(PYTHON) scripts/abi_audit.py --binary $(DEBUG_DIR)/asmflow-tests

gate-m2: gate-m1 test-unit abi-audit test-crash valgrind-unit
	@printf 'M2 gate passed for AsmFlow %s\n' '$(VERSION)'

# ---------------------------------------------------------------------------
# M3 targets: JSON, configuration, and secret references.
# ---------------------------------------------------------------------------
test-config: build-tests
	$(DEBUG_DIR)/asmflow-tests --filter config/ --verbose
	$(DEBUG_DIR)/asmflow-tests --filter json/ --verbose

test-config-parity: build-debug build-tests
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_config_parity

# HARNESS.md M3 DoD 7. The iteration count is a variable so a developer can run
# a shorter pass locally, but the gate always uses the full ten thousand.
RELOAD_SOAK_ITERATIONS ?= 10000
test-config-reload-soak: build-tests
	$(DEBUG_DIR)/asmflow-tests --reload-soak $(RELOAD_SOAK_ITERATIONS)

valgrind-config: build-tests
	valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite \
	  --errors-for-leak-kinds=definite --track-origins=yes \
	  --error-exitcode=99 \
	  $(DEBUG_DIR)/asmflow-tests --reload-soak 200

gate-m3: gate-m2 build-debug test-config-parity valgrind-config
	$(PYTHON) scripts/gate_m3.py --build-dir $(BUILD_DIR) \
	  --soak-iterations $(RELOAD_SOAK_ITERATIONS)
	@printf 'M3 gate passed for AsmFlow %s\n' '$(VERSION)'

# ---------------------------------------------------------------------------
# M4 targets: SQLite, migrations, and the control plane.
# ---------------------------------------------------------------------------
test-migrations: build-tests
	$(DEBUG_DIR)/asmflow-tests --filter db/ --verbose

test-storage: build-tests
	$(DEBUG_DIR)/asmflow-tests --filter db/ --verbose
	$(DEBUG_DIR)/asmflow-tests --filter jsonw/ --verbose

test-control: build-debug build-tests
	$(DEBUG_DIR)/asmflow-tests --filter loop/ --verbose
	$(DEBUG_DIR)/asmflow-tests --filter ctlframe/ --verbose
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_control_protocol

# HARNESS.md M4 DoD 7 lives inside the integration suite, which counts the
# daemon's own /proc/<pid>/fd entries before and after a hundred cycles.
test-control-fd-soak: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v \
	  tests.test_control_protocol.ControlProtocolTests.test_a_hundred_connections_leak_no_descriptors \
	  tests.test_control_protocol.ControlProtocolTests.test_abrupt_disconnects_are_reclaimed

valgrind-storage: build-tests
	valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite \
	  --errors-for-leak-kinds=definite --track-origins=yes \
	  --error-exitcode=99 \
	  $(DEBUG_DIR)/asmflow-tests --filter db/
	valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite \
	  --errors-for-leak-kinds=definite --track-origins=yes \
	  --error-exitcode=99 \
	  $(DEBUG_DIR)/asmflow-tests --filter loop/

gate-m4: gate-m3 test-control-fd-soak valgrind-storage
	$(PYTHON) scripts/gate_m4.py --build-dir $(BUILD_DIR)
	@printf 'M4 gate passed for AsmFlow %s\n' '$(VERSION)'

# ---------------------------------------------------------------------------
# M5 targets: the gateway HTTP listener and its contract.
#
# Each suite is its own target because each answers a different question, and a
# failure should say which one without anybody having to read a traceback.
# HARNESS.md M5 names these commands directly.
# ---------------------------------------------------------------------------
test-http: build-tests
	$(DEBUG_DIR)/asmflow-tests --filter http/ --verbose

test-http-contract: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_http_contract

test-http-limits: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_http_limits

test-http-smuggling: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_http_smuggling

test-http-fragments: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_http_fragments

test-http-faults: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_http_faults

test-http-soak: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_http_soak

valgrind-http: build-tests
	valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite \
	  --errors-for-leak-kinds=definite --track-origins=yes \
	  --error-exitcode=99 \
	  $(DEBUG_DIR)/asmflow-tests --filter http/

gate-m5: gate-m4 test-http test-http-contract test-http-limits \
         test-http-smuggling test-http-fragments test-http-faults \
         test-http-soak valgrind-http
	$(PYTHON) scripts/gate_m5.py --build-dir $(BUILD_DIR) --skip-suites
	@printf 'M5 gate passed for AsmFlow %s\n' '$(VERSION)'

package: check
	@mkdir -p dist
	@zip -qr 'dist/$(PACKAGE_NAME)-$(VERSION).zip' . \
	  -x 'dist/*' '.git/*' 'build/*' '__pycache__/*' '*/__pycache__/*' '*.pyc'
	@printf 'Created dist/%s-%s.zip\n' '$(PACKAGE_NAME)' '$(VERSION)'

clean:
	rm -rf build dist coverage __pycache__ tests/__pycache__ scripts/__pycache__
