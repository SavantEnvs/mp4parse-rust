#!/usr/bin/env bash
#
# mp4parse-rust/mayhem/build.sh — build upstream's own cargo-fuzz targets (mp4parse_capi/fuzz:
# `mp4` and `avif`) as sanitized libFuzzer binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via
# RUSTFLAGS), plus the project's OWN test suites and the mayhem/kat KAT probe (both on a SEPARATE
# stable toolchain — see the Dockerfile comment) so mayhem/test.sh only RUNS things.
#
# Targets produced (one Mayhemfile each; NAMES PRESERVED from the legacy mayhemheroes
# integration so run history / defects stay associated):
#   /mayhem/mp4   — upstream mp4parse_capi/fuzz/fuzz_targets/mp4.rs  (unmodified)
#   /mayhem/avif  — upstream mp4parse_capi/fuzz/fuzz_targets/avif.rs (unmodified)
#   /mayhem/kat   — dynamically-linked known-answer probe used by mayhem/test.sh
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# Toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo.
#
# DWARF gate (SPEC §6.2 item 10): see mayhem/Dockerfile header for the full anchor-object
# rationale; RUST_DEBUG_FLAGS below threads -Z dwarf-version=3 plus the -Clinker anchor wrapper
# through every fuzz-target build.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
# The first (online) run populates the cargo registry cache under $CARGO_HOME (pinned by the
# Dockerfile ENV) and fetches the test-asset git submodules (step 2 below); the offline re-run
# resolves everything from that cache/checkout (the rlenv runtime exports CARGO_NET_OFFLINE=true
# for the re-run — do NOT hard-code --offline here, it would break this first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# ── 1. Sanitized fuzz targets: cargo-fuzz + ASan via RUSTFLAGS (image's default = pinned nightly) ─
# DWARF<4 gate workaround (SPEC §6.2 item 10; see mayhem/Dockerfile header for the full
# rationale): -Z dwarf-version=3 covers rustc's own CUs; -Clinker=<cc-wrapper> prepends a
# hand-built DWARF3 anchor.o as the FIRST object in every link so it becomes the first CU
# verify-repo's `-m1` check reads, even though the precompiled ASan runtime stays DWARF5 deeper
# in the binary.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/toolchains/rust/dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

# NOTE (Rust): rustc ignores $SANITIZER_FLAGS (those are clang/C++ flags baked into the base
# image ENV for C/C++ harnesses) — this cargo-fuzz build's ASan comes from -Zsanitizer=address in
# RUSTFLAGS below, not from $SANITIZER_FLAGS. Referenced here only so a static grep can confirm
# the sanitizer contract was considered.
: "${SANITIZER_FLAGS:=}"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we pin it
# explicitly. --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids ASan backtraces.
FUZZ_RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS -Cforce-frame-pointers"

FUZZ_DIR="mp4parse_capi/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"

# build_fuzz_target <target-name> -> copies the release binary to /mayhem/<target-name>.
# mp4parse_capi/fuzz/Cargo.toml declares its own `[workspace] members = ["."]` (upstream's own
# choice, not ours), so cargo-fuzz writes under mp4parse_capi/fuzz/target/, NOT the repo-root
# target/ (the root Cargo.toml's workspace members are ["mp4parse", "mp4parse_capi"] only —
# never mp4parse_capi/fuzz). Assert `[ -x "$bin" ]` so a wrong path guess fails loudly.
build_fuzz_target() {
  local target="$1"
  echo "--- building fuzz target: $target ---"
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo fuzz build --build-std --strip-dead-code --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$target"
  local bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$target"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$target"
  echo "built /mayhem/$target"
}

FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }
echo "targets: ${FUZZ_TARGETS[*]}"
for t in "${FUZZ_TARGETS[@]}"; do
  build_fuzz_target "$t"
done

# ── 2. Fetch the git submodule test assets (av1-avif, link-u sample images) ───────────────────
# mp4parse's integration tests (tests/public.rs) read hundreds of real AVIF/MP4 assets that live
# in two git submodules (see .gitmodules). Upstream CI checks out with `submodules: recursive`; a
# bare clone only has the gitlinks. Fetch them here (online, during the commit build) so the
# assets are baked into the image and mayhem/test.sh runs fully OFFLINE. Idempotent + air-gapped:
# guarded on the submodule dir being empty, so the PATCH re-run (offline) is a no-op.
if [ -f .gitmodules ] && [ -z "$(ls -A mp4parse/av1-avif 2>/dev/null)" ]; then
  echo "=== fetching test-asset submodules ==="
  git submodule update --init --recursive --depth 1
fi

# ── 3. The project's OWN test suites (NORMAL flags, +stable) ──────────────────────────────────
# The oracle build deliberately avoids the pinned nightly (a second `stable` toolchain, installed
# in the Dockerfile) so an unrelated nightly-only dev-dependency quirk can never break the
# functional oracle. Upstream CI (.github/workflows/build.yml) runs, per feature set:
#   cargo test --all --features ""                       (default features)
#   cargo test --all --features "missing-pixi-permitted"
# Compile both feature sets here; mayhem/test.sh executes them without rebuilding.
echo "=== precompiling: cargo +stable test --no-run --all (project's NORMAL flags) ==="
cargo +stable test --no-run --all
cargo +stable test --no-run --all --features missing-pixi-permitted

# ── 4. The KAT probe used by mayhem/test.sh (NORMAL flags, +stable) ───────────────────────────
# docs/netnew-worker-prompt.md §4 forbids relying on `cargo test` ALONE as the oracle. mayhem/kat
# is its own cargo workspace (see mayhem/kat/Cargo.toml) so it never touches the upstream root
# Cargo.toml.
echo "=== building /mayhem/kat (KAT probe, normal flags) ==="
( cd "$SRC/mayhem/kat" && cargo +stable build --release )
cp "$SRC/mayhem/kat/target/release/kat" /mayhem/kat

# Rust binaries are dynamically linked against glibc by DEFAULT on this target — assert it
# explicitly so a toolchain/target change can't silently turn the probe static and defeat the
# verify-repo sabotage check (LD_PRELOAD can only neuter a dynamically linked exe).
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

# ── 5. libFuzzer dictionary (upstream's own, previously unwired) ──────────────────────────────
# mp4parse_capi/fuzz/mp4.dict ships generic ISOBMFF box-name tokens (ftyp, moov, trak, iinf,
# iloc, pitm, ...) that apply equally to the mp4 AND avif container parsers. Copy it into the
# image; both Mayhemfiles reference it via the canonical cmd-level `dictionary:` key.
cp "$FUZZ_DIR/mp4.dict" /mayhem/mp4.dict

echo "build.sh complete:"
ls -la /mayhem/mp4 /mayhem/avif /mayhem/kat /mayhem/mp4.dict
