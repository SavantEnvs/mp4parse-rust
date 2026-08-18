#!/usr/bin/env bash
#
# mp4parse-rust/mayhem/test.sh — RUN the project's OWN upstream test suites AND the KAT probe,
# and emit a CTRF summary. exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3 / docs/netnew-worker-prompt.md §4). Two parts:
#
#  1) `cargo +stable test --all [--features missing-pixi-permitted]` — mirrors upstream CI
#     (.github/workflows/build.yml): mp4parse's unit tests (src/tests.rs) and integration tests
#     (tests/public.rs & friends) parse dozens of checked-in mp4/avif/3gp assets and assert exact
#     parsed structure (track counts, codecs, dimensions, expected-error results for corrupt
#     files); mp4parse_capi's tests assert the C API surface. Real assertions on real computed
#     values, not "exits 0".
#
#  2) The KAT probe /mayhem/kat — docs/netnew-worker-prompt.md §4 forbids relying on `cargo test`
#     ALONE as the oracle. /mayhem/kat is a small, purpose-built, dynamically-linked binary
#     (build.sh asserts `file` reports "dynamically linked", failing the build otherwise) that
#     parses three FIXED media fixtures (embedded via include_bytes!, no runtime file I/O) through
#     mp4parse_capi's real public C API and panics on any mismatch, printing exact
#     `KAT_<NAME>=<value>` lines. A neutered binary (verify-repo's LD_PRELOAD shim `_exit(0)`s it
#     before any of this runs) prints nothing, so every `grep -qxF` below fails.
#
# Everything was compiled by mayhem/build.sh (cargo test --no-run + the kat binary, both on the
# +stable toolchain, normal flags) — this script only RUNS things (offline-safe).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export RUSTUP_HOME="${RUSTUP_HOME:-/opt/toolchains/rust/rustup}"
export CARGO_HOME="${CARGO_HOME:-/opt/toolchains/rust/cargo}"
export PATH="$CARGO_HOME/bin:$PATH"
: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

PASSED=0; FAILED=0; SKIPPED=0
LOG="$SRC/mayhem-test.log"
: > "$LOG"

# run_suite <label> <cargo test args...>
# Runs one upstream `cargo +stable test` invocation and accumulates the libtest
# "test result: ok. N passed; M failed; S ignored; ..." summary lines (one per test binary).
run_suite() {
  local label="$1"; shift
  echo "=== running: cargo +stable test $* ($label) ==="
  local out rc=0
  out="$(cargo +stable test "$@" 2>&1)" || rc=$?
  echo "$out" | tail -25
  echo "$out" >> "$LOG"
  local p=0 f=0 s=0
  while read -r pp ff ss; do
    p=$(( p + pp )); f=$(( f + ff )); s=$(( s + ss ))
  done < <(echo "$out" | grep -E '^test result:' | sed -E 's/^test result: [a-zA-Z]+\. ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored;.*/\1 \2 \3/')
  if [ "$(( p + f + s ))" -eq 0 ]; then
    # No libtest summaries at all (build error / neutered runner) — that's a failure.
    echo "ERROR: no test results parsed from '$label' (rc=$rc)" >&2
    f=1
  fi
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; fi   # honest on non-zero exits
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); SKIPPED=$(( SKIPPED + s ))
}

run_suite "default features"       --all
run_suite "missing-pixi-permitted" --all --features missing-pixi-permitted

# ── The KAT probe (sabotage-detecting; see header) ─────────────────────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A `[ -x ... ]` guard here
# is how a probe silently stops running and the oracle quietly degrades.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed VALUES from real media) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or the parser is broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "video_rotation_90.mp4: track_count=1, rotation=90"                 'KAT_ROTATION=90'
kat_expect "sine-3s-xhe-aac-44khz-mono.mp4: track_count=1, track_type=Audio"   'KAT_XHEAAC_TRACK_TYPE=Audio'
kat_expect "no_edts.avif: colour-track timescale=16384"                       'KAT_AVIF_TIMESCALE=16384'

emit_ctrf "cargo-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
