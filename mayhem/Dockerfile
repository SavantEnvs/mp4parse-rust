# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for mp4parse-rust (mp4/AVIF parser; cargo-fuzz targets in upstream's own
# mp4parse_capi/fuzz). Builds ON TOP of the org base image, adding a pinned Rust nightly +
# cargo-fuzz under /opt/toolchains/rust (SPEC §6.2 item 8), plus a DWARF3 "anchor" object used to
# satisfy the DWARF<4 gate against the ASan runtime's DWARF5 archive (SPEC §6.2 item 10 — see
# mayhem/build.sh for the full rationale).
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t mp4parse-rust-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS

# ── Rust toolchain @ a FIXED, lockable, $HOME-independent prefix ───────────────────────────
# Nightly is required for -Zsanitizer=address (the OSS-Fuzz Rust ASan path) and for
# -Z dwarf-version=3. nightly-2025-01-15 is known to ICE compiling some crates under
# -Zsanitizer=address; nightly-2025-09-05 is fleet-proven good (see jaq's port).
ARG RUST_CHANNEL=nightly-2025-09-05
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root

RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 # A SECOND, stable toolchain for the oracle path (the project's own `cargo test` suite + the
 # mayhem/kat probe): keeps the functional-oracle build off the pinned nightly, so an unrelated
 # nightly-only dev-dependency quirk can never break the oracle (see mayhem/build.sh). The fuzz
 # targets still build/link on nightly (required for -Zsanitizer=address).
 && rustup toolchain install stable --profile minimal --no-self-update \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must read the
 # toolchain and read/refresh the cargo registry cache, so hand the whole prefix to 2000.
 && chown -R 2000:2000 /opt/toolchains/rust

# ── DWARF<4 anchor (SPEC §6.2 item 10) ─────────────────────────────────────────────────────
# cargo-fuzz's ASan build links a precompiled `librustc-nightly_rt.asan.a` runtime archive
# (DWARF5) via --whole-archive, and it lands FIRST in the final binary's .debug_info — so plain
# rustc debuginfo flags (which only affect rustc's OWN compilation units) can't fix the first-CU
# check verify-repo runs. Fix: prepend a hand-built DWARF3 compile-unit as the FIRST object in
# every link via a `-Clinker=<cc-wrapper>` RUSTFLAG — .debug_info CUs appear in linker-argument
# order, so the anchor's DWARF3 CU lands at offset 0. This is a first-CU-only, cosmetic fix — the
# rest of the binary (asan runtime + most rustc-emitted CUs) stays DWARF4/5; fuzzing and
# crash-finding are unaffected, only debug-info triage of the bulk of the binary.
RUN set -eux; \
    mkdir -p /opt/toolchains/rust/dwarf3-anchor; \
    printf 'int __mayhem_dwarf3_anchor;\n' \
      > /opt/toolchains/rust/dwarf3-anchor/anchor.c; \
    clang -g -gdwarf-3 -c /opt/toolchains/rust/dwarf3-anchor/anchor.c \
      -o /opt/toolchains/rust/dwarf3-anchor/anchor.o; \
    printf '#!/bin/bash\nexec cc /opt/toolchains/rust/dwarf3-anchor/anchor.o "$@"\n' \
      > /opt/toolchains/rust/dwarf3-anchor/cc-wrapper.sh; \
    chmod +x /opt/toolchains/rust/dwarf3-anchor/cc-wrapper.sh; \
    chmod a+rX /opt/toolchains/rust/dwarf3-anchor /opt/toolchains/rust/dwarf3-anchor/anchor.o \
               /opt/toolchains/rust/dwarf3-anchor/cc-wrapper.sh; \
    echo "DWARF3 anchor ready: $(readelf --debug-dump=info /opt/toolchains/rust/dwarf3-anchor/anchor.o | grep -m1 Version:)"

USER mayhem

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git history) → /mayhem.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz targets + KAT probe.
RUN bash mayhem/build.sh

# Run the project's functional suite + the KAT probe at build time (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
