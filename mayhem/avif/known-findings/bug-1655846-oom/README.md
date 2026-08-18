# Unbounded allocation before size validation (AVIF `iloc`/`meta`, ~4 GiB malloc)

**Reproducer:** `repro.avif` (a small, already-known-corrupt fixture upstream ships at
`mp4parse/tests/corrupt/bug-1655846.avif`, referencing Mozilla bug 1655846).

**Cause:** parsing this file through `mp4parse_capi::mp4parse_avif_new` (the C API our
`avif` fuzz harness drives, `mp4parse_capi/fuzz/fuzz_targets/avif.rs`) attempts a single
allocation of `malloc(4294639634)` (~4 GiB) — driven directly by an attacker-controlled
size field read from the file — before the code has validated that field against the
actual (tiny) input length. Under the ASan build used for fuzzing, libFuzzer's malloc-size
guard aborts the process immediately with `libFuzzer: out-of-memory (malloc(4294639634))`.

**Why it isn't caught by upstream's own test:** `mp4parse/tests/public.rs::public_avif_bug_1655846`
calls the pure-Rust `mp4parse::read_avif` directly (no ASan, default system allocator) and only
asserts `.is_err()`. A ~4 GiB allocation request under glibc's overcommit is typically satisfied
instantly without touching the memory, so the function proceeds to fail validation and returns
`Err` normally — the test passes without ever observing the oversized-allocation step. The
allocation-before-validation ordering is real regardless; it just doesn't abort outside of an
ASan/malloc-limited environment.

**Impact:** a crafted AVIF/HEIF file can make a consumer of `mp4parse_capi` attempt a large,
attacker-sized allocation before any structural validation of the advertised size against the
input's actual length — a classic allocate-before-validate DoS pattern (excessive memory
pressure / OOM-kill on constrained hosts, even though Rust's `Vec`/allocator itself won't
overflow-UB).

**Upstream fix (one line, sketch):** validate the box/extent size against `context.len()` (or the
declared file length) *before* calling the allocator, in whatever `mp4parse` codepath computes the
allocation size for this AVIF item/extent (see `AvifContext`'s `iloc`/`meta`/spatial-extents
handling reached from `mp4parse::read_avif`). This mirrors the same allocate-after-validate
pattern mp4parse already uses elsewhere (see the various `BoxSize`/`checked_add` guards in
`mp4parse/src/boxes.rs`).

**Why this file is NOT in `mayhem/avif/testsuite/`:** seeds are replayed on every fuzz run. A seed
that deterministically OOM-aborts on load reliably crashes the process before the corpus finishes
loading, on every single run — it doesn't get fuzzed further, it just stalls exploration on
rediscovering the same allocation every restart (the same class of problem as a hang seed). Kept
here instead as a standalone reproducer, per docs/netnew-worker-prompt.md's known-findings
convention.

**Repro:**
```
./avif -rss_limit_mb=2048 -runs=1 mayhem/avif/known-findings/bug-1655846-oom/repro.avif
# ==NNNN== ERROR: libFuzzer: out-of-memory (malloc(4294639634))
```
