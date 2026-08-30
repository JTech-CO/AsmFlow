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
SRC_FFI_DAEMON := src/ffi/sqlite_shim.c src/ffi/llhttp_shim.c src/ffi/curl_shim.c
SRC_FFI_TEST   := src/ffi/abi_probe.c
SRC_FFI_C      := $(SRC_FFI_SHARED) $(SRC_FFI_DAEMON) $(SRC_FFI_TEST)

# Assembly test sources. The unit-test binary links every runtime module except
# the two entry points, so a test may call any exported function directly.
SRC_TEST_ASM := $(wildcard tests/asm/*.asm)
# Test-only C. The routing parity bridge reads a JSON corpus and drives the
# assembly selector over it; it decides nothing and knows no structure offsets,
# which is why it is allowed to exist on this side of the boundary at all.
SRC_TEST_C   := $(wildcard tests/ffi/*.c)

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
             $(SRC_FFI_DAEMON) $(SRC_FFI_TEST) $(SRC_TEST_C)

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
        test-provider test-provider-contract test-sse-fragments \
        test-backpressure test-client-cancel test-provider-faults \
        test-stream-soak valgrind-provider \
        test-routing test-routing-parity test-circuit-timeline \
        test-fallback-invariant test-routing-concurrency \
        test-routing-fault-soak valgrind-routing \
        test-mcp-stdio-modern test-mcp-stdio-legacy \
        test-mcp-stdio-malformed test-mcp-process-lifecycle \
        test-mcp-crash-loop test-mcp-zombie-soak valgrind-mcp \
        test-mcp-http-modern test-mcp-http-legacy \
        test-mcp-version-matrix test-mcp-http-stream \
        test-mcp-http-security \
        gate-m0 gate-m1 gate-m2 gate-m3 gate-m4 gate-m5 gate-m6 gate-m7 gate-m8 gate-m9 \
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
	  '  make test-mcp-stdio-modern   Modern MCP stdio discovery/inventory' \
	  '  make test-mcp-stdio-legacy   Legacy initialize/inventory adapter' \
	  '  make test-mcp-stdio-malformed  Protocol corruption and readiness' \
	  '  make test-mcp-process-lifecycle  argv/env/cwd/shutdown lifecycle' \
	  '  make test-mcp-crash-loop     Restart budget and manual reset' \
	  '  make test-mcp-zombie-soak    Repeated restart/stop/start reaping' \
	  '  make test-mcp-http-modern    Modern MCP HTTP headers and JSON/SSE' \
	  '  make test-mcp-http-legacy    Legacy session and GET-stream adapter' \
	  '  make test-mcp-version-matrix HTTP version/error era selection' \
	  '  make test-mcp-http-stream    Fragmented SSE and cancellation' \
	  '  make test-mcp-http-security  URL/auth/redirect/proxy/cache policy' \
	  '' \
	  'Milestone gates:' \
	  '  make gate-m0        Specification and contract scaffold' \
	  '  make gate-m1        Toolchain and build foundation' \
	  '  make gate-m2        ABI, memory, and core primitives' \
	  '  make gate-m3        JSON, configuration, and secret references' \
	  '  make gate-m4        SQLite, migrations, and the control plane' \
	  '  make gate-m5        Gateway HTTP listener and contract' \
	  '  make gate-m6        Upstream client, Responses/Chat, streaming' \
	  '  make gate-m7        Routing, health, circuit breaking, fallback' \
	  '  make gate-m8        MCP stdio process supervision' \
	  '  make gate-m9        MCP Streamable HTTP and version adapters' \
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

# ---------------------------------------------------------------------------
# M6 targets: the upstream client, Responses/Chat, and streaming.
#
# Every suite here runs against `tests/mock_provider.py`, a provider whose wire
# bytes the test writes directly. A real provider could not be asked to split
# an event across two packets or to stop talking mid-sentence, and those are
# the cases M6 exists to get right.
# ---------------------------------------------------------------------------
test-provider: build-tests
	$(DEBUG_DIR)/asmflow-tests --filter prov/ --verbose

test-provider-contract: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_provider_contract

test-sse-fragments: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_provider_streaming

test-backpressure: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v \
	  tests.test_provider_faults.BackpressureTests \
	  tests.test_provider_faults.CapacityTests

test-client-cancel: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v \
	  tests.test_provider_faults.CancellationTests \
	  tests.test_provider_faults.DescriptorTests

test-provider-faults: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_provider_faults

# HARNESS.md M6 DoD 8 asks for an hour. An hour is not a CI step, so the volume
# is a parameter and the assertions are not: set ASMFLOW_SOAK_SECONDS to run
# the release-verification length.
test-stream-soak: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_provider_soak

# `still reachable` is non-zero here and is not a defect: linking libcurl pulls
# in GnuTLS, whose ELF constructors allocate global state before main and never
# free it. The gate asserts `definitely lost` is zero, which is the part AsmFlow
# is responsible for.
valgrind-provider: build-tests
	valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite \
	  --errors-for-leak-kinds=definite --track-origins=yes \
	  --error-exitcode=99 \
	  $(DEBUG_DIR)/asmflow-tests --filter prov/

gate-m6: gate-m5 test-provider test-provider-contract test-sse-fragments \
         test-provider-faults test-stream-soak valgrind-provider
	$(PYTHON) scripts/gate_m6.py --build-dir $(BUILD_DIR) --skip-suites
	@printf 'M6 gate passed for AsmFlow %s\n' '$(VERSION)'

# ---------------------------------------------------------------------------
# M7 targets: routing, health, circuit breaking, and fallback.
#
# The parity target is the one that matters most. `tests/route_oracle.py`
# states the selection rules in Python and `src/routing/` states them in
# assembly; the corpus runs both over the same scenarios and fails on any
# disagreement. A routing defect answers the request and looks correct, so
# "does it work" is not a question a test can ask here — "does it agree with an
# independent statement of the rules" is.
# ---------------------------------------------------------------------------
test-routing: build-tests
	$(DEBUG_DIR)/asmflow-tests --filter route/ --verbose

test-routing-parity: build-tests
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_routing_parity

test-circuit-timeline: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_circuit_timeline

test-fallback-invariant: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_fallback_invariant

test-routing-concurrency: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_routing_concurrency

test-routing-fault-soak: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_routing_fault_soak

valgrind-routing: build-tests
	valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite \
	  --errors-for-leak-kinds=definite --track-origins=yes \
	  --error-exitcode=99 \
	  $(DEBUG_DIR)/asmflow-tests --filter route/

gate-m7: gate-m6 test-routing test-routing-parity test-circuit-timeline \
         test-fallback-invariant test-routing-concurrency \
         test-routing-fault-soak valgrind-routing
	$(PYTHON) scripts/gate_m7.py --build-dir $(BUILD_DIR) --skip-suites
	@printf 'M7 gate passed for AsmFlow %s\n' '$(VERSION)'

# ---------------------------------------------------------------------------
# M8 targets: MCP stdio process supervision.
#
# HARNESS.md names these targets directly.  Each recipe is intentionally a
# focused set: a modern adapter failure must not be hidden inside a broad
# lifecycle run, and a crash-budget regression must not require reading past
# unrelated argv/environment results to find it.
# ---------------------------------------------------------------------------
test-mcp-stdio-modern: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v \
	  tests.test_mcp_process_lifecycle.McpProcessLifecycleTests.test_modern_startup_method_sequence \
	  tests.test_mcp_process_lifecycle.McpProcessLifecycleTests.test_invalid_modern_success_without_legacy_fails_before_inventory

test-mcp-stdio-legacy: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v \
	  tests.test_mcp_process_lifecycle.McpProcessLifecycleTests.test_legacy_startup_method_sequence \
	  tests.test_mcp_process_lifecycle.McpProcessLifecycleTests.test_invalid_modern_success_falls_back_without_era_interleave \
	  tests.test_mcp_process_lifecycle.McpProcessLifecycleTests.test_invalid_legacy_success_fails_before_initialized \
	  tests.test_mcp_process_supervision.McpLegacyProcessResetTests

test-mcp-stdio-malformed: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v \
	  tests.test_mcp_process_supervision.McpMalformedStdioTests \
	  tests.test_mcp_process_supervision.McpRequiredReadinessTests

test-mcp-process-lifecycle: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v \
	  tests.test_mcp_process_lifecycle.McpProcessLifecycleTests.test_arguments_are_literal_and_never_reach_a_shell \
	  tests.test_mcp_process_lifecycle.McpProcessLifecycleTests.test_environment_is_allowlisted_and_secret_sources_do_not_leak \
	  tests.test_mcp_process_lifecycle.McpProcessLifecycleTests.test_configured_working_directory_is_applied \
	  tests.test_mcp_process_lifecycle.McpProcessLifecycleTests.test_child_is_gone_after_daemon_shutdown \
	  tests.test_mcp_process_supervision.McpRequestTimeoutTests

test-mcp-crash-loop: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v \
	  tests.test_mcp_process_supervision.McpCrashLoopTests

test-mcp-zombie-soak: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v \
	  tests.test_mcp_process_supervision.McpZombieSoakTests

valgrind-mcp: build-tests
	valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite \
	  --errors-for-leak-kinds=definite --track-origins=yes \
	  --error-exitcode=99 \
	  $(DEBUG_DIR)/asmflow-tests --filter mcp/

gate-m8: gate-m7 test-mcp-stdio-modern test-mcp-stdio-legacy \
         test-mcp-stdio-malformed test-mcp-process-lifecycle \
         test-mcp-crash-loop test-mcp-zombie-soak valgrind-mcp
	$(PYTHON) scripts/gate_m8.py --build-dir $(BUILD_DIR) --skip-suites
	@printf 'M8 gate passed for AsmFlow %s\n' '$(VERSION)'

# ---------------------------------------------------------------------------
# M9 targets: MCP Streamable HTTP and version-isolated adapters.
#
# These five targets are the behavioural groups named by HARNESS.md.  The
# static audit is kept in gate_m9.py; gate-m9 first proves that every M8
# invariant still holds, then runs each HTTP group and the native MCP memcheck.
# ---------------------------------------------------------------------------
test-mcp-http-modern: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_mcp_http_modern

test-mcp-http-legacy: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_mcp_http_legacy

test-mcp-version-matrix: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_mcp_version_matrix

test-mcp-http-stream: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_mcp_http_stream

test-mcp-http-security: build-debug
	BUILD_DIR=$(BUILD_DIR) $(PYTHON) -m unittest -v tests.test_mcp_http_security

gate-m9: gate-m8 test-mcp-http-modern test-mcp-http-legacy \
         test-mcp-version-matrix test-mcp-http-stream \
         test-mcp-http-security valgrind-mcp
	$(PYTHON) scripts/gate_m9.py --build-dir $(BUILD_DIR) --skip-suites
	@printf 'M9 gate passed for AsmFlow %s\n' '$(VERSION)'

package: check
	@mkdir -p dist
	@zip -qr 'dist/$(PACKAGE_NAME)-$(VERSION).zip' . \
	  -x 'dist/*' '.git/*' 'build/*' '__pycache__/*' '*/__pycache__/*' '*.pyc'
	@printf 'Created dist/%s-%s.zip\n' '$(PACKAGE_NAME)' '$(VERSION)'

clean:
	rm -rf build dist coverage __pycache__ tests/__pycache__ scripts/__pycache__
