#!/usr/bin/env bash
#
# mayhem/build.sh — build libccv's fuzz harnesses (sanitized) and its unit-test runners (normal flags).
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem; safe to re-run, offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS SRC

cd "$SRC"

# `make -C lib` / `make -C test/...` run the default `all`, which downloads a 220 MB VGG model;
# build only the `libccv.a` target and compile the test runners by hand, so nothing needs the network.
configure_lib() { (cd lib && ./configure CC="$CC" CPPFLAGS="$1" LDFLAGS="$2" >/dev/null); }
clean_lib() { make -C lib clean >/dev/null 2>&1 || true; }
lib_ldflags() { printf 'include lib/config.mk\nprint:\n\t@echo $(LDFLAGS)\n' | make -s -f - print; }

# 1) Test suite with the project's NORMAL flags (statically links its own libccv.a copy).
clean_lib
configure_lib "$COVERAGE_FLAGS" "$COVERAGE_FLAGS"
make -C lib -j"$MAYHEM_JOBS" libccv.a >/dev/null
LIBS="$(lib_ldflags)"
CFLAGS_T="$(printf 'include lib/config.mk\nprint:\n\t@echo $(CFLAGS)\n' | make -s -f - print)"
build_test() {
	local src="$1" dir out
	dir="$(dirname "$src")"
	out="${src%.c}"; out="${out%.tests}.tests"
	( cd "$dir" && $CC -O3 -Wall -I"$SRC/lib" -I"$SRC/test" $CFLAGS_T $COVERAGE_FLAGS "$(basename "$src")" -o "$(basename "$out")" -L"$SRC/lib" -lccv $LIBS )
}
export -f build_test
export SRC CC CFLAGS_T COVERAGE_FLAGS LIBS
ls test/unit/*.tests.c test/unit/nnc/*.tests.c test/regression/*.tests.c | xargs -P "$MAYHEM_JOBS" -I{} bash -c 'build_test {}'

# 2) Sanitized, coverage-instrumented library for the fuzz targets (fuzzer-no-link is unconditional so
#    the library has SanCov edges even when SANITIZER_FLAGS is empty).
clean_lib
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
configure_lib "$FUZZ_CFLAGS" "$SANITIZER_FLAGS"
make -C lib -j"$MAYHEM_JOBS" libccv.a >/dev/null
LIBS="$(lib_ldflags)"

# 3) Harnesses: libFuzzer binary + standalone run-once reproducer, LSan disabled at build time.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

declare -A HARNESS=( [csv_fuzz]="$SRC/mayhem/csv_fuzz.c" [ccv_read_fuzz]="$SRC/mayhem/ccv_read_fuzz.c" )
for name in "${!HARNESS[@]}"; do
	$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $LIB_FUZZING_ENGINE \
		"${HARNESS[$name]}" /tmp/lsan_off.o -I"$SRC/lib" -L"$SRC/lib" -lccv $LIBS -o "/mayhem/$name"
	$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link \
		"${HARNESS[$name]}" /tmp/standalone_main.o /tmp/lsan_off.o -I"$SRC/lib" -L"$SRC/lib" -lccv $LIBS -o "/mayhem/$name-standalone"
done
