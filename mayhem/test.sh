#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libccv's own unit tests (built with normal flags by mayhem/build.sh).
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


# Each *.tests binary is ccv's case runner: it prints one `[PASS]`/`[FAIL]`/`[SKIP]` line per test case,
# asserting computed values against golden data (test/unit/data, known-answer tensors). A binary that
# produces no case lines at all (crashed, or neutered to exit(0)) counts as a failure.
# Some upstream cases (e.g. the cnnp.core LoRA GEMM fine-tuning ones) train from a randomly initialised
# layer and only converge within tolerance most of the time, so a failing runner is retried (3 attempts
# max); a deterministic regression fails every attempt.
passed=0; failed=0; skipped=0
for t in test/unit/*.tests test/unit/nnc/*.tests test/regression/*.tests; do
  [ -x "$t" ] || { echo "missing test runner $t (mayhem/build.sh builds it)" >&2; failed=$((failed+1)); continue; }
  for attempt in 1 2 3; do
    out="$(cd "$(dirname "$t")" && timeout 600 "./$(basename "$t")" 2>&1 | tr '\r' '\n')"
    p=$(printf '%s\n' "$out" | grep -c '\[PASS\]' || true)
    f=$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)
    s=$(printf '%s\n' "$out" | grep -c '\[SKIP\]' || true)
    [ $((p+f+s)) -gt 0 ] || { f=1; echo "no test cases reported by $t" >&2; }
    [ "$f" -eq 0 ] && break
    echo "FAIL in $t (attempt $attempt)" >&2; printf '%s\n' "$out" | grep '\[FAIL\]' >&2 || true
  done
  passed=$((passed+p)); failed=$((failed+f)); skipped=$((skipped+s))
done
emit_ctrf "ccv-case" "$passed" "$failed" "$skipped"
