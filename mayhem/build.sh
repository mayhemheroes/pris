#!/usr/bin/env bash
#
# mayhem/build.sh — build pris's cargo-fuzz target (lexer+parser harness, ported from the
# original mayhemheroes integration) as a sanitized libFuzzer binary, PLUS the project's
# own test artifacts (cargo test binaries + the release `pris` binary that
# tests/compile_examples.py drives) with the project's NORMAL flags, so mayhem/test.sh
# only RUNS them.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the
#     crates.io index over the (absent) network — so do NOT hard-code `--offline` here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# The repo root carries a rust-toolchain file pinning 1.28.0 (2018). The image ships ONE
# pinned nightly under /opt/toolchains/rust; honoring the file would make rustup try to
# download 1.28.0 (impossible offline). The Dockerfile exports RUSTUP_TOOLCHAIN to override
# the file; belt-and-braces default it here too.
: "${RUSTUP_TOOLCHAIN:=$(ls "${RUSTUP_HOME:-/opt/toolchains/rust/rustup}/toolchains" | head -1)}"
export RUSTUP_TOOLCHAIN

# SANITIZER off-switch (SPEC): the Dockerfile threads $SANITIZER_FLAGS (default asan+ubsan,
# halting). rustc ignores clang flags, so we DERIVE the rustc sanitizer flag from it: if
# $SANITIZER_FLAGS mentions "address" we add -Zsanitizer=address; an EMPTY value (built with
# --build-arg SANITIZER_FLAGS=) yields a natural, un-instrumented crash build.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all}"
RUST_SAN=""
CFZ_SANITIZER="none"   # cargo-fuzz's own -s flag; overridden below when ASan is requested
case "$SANITIZER_FLAGS" in
  *address*) RUST_SAN="-Zsanitizer=address"; CFZ_SANITIZER="address" ;;
esac

# DWARF < 4 contract (§6.2 item 10): clang-19 / recent rustc default to DWARF-5, which Mayhem's
# triage can't read. Thread $RUST_DEBUG_FLAGS so every fuzz binary carries DWARF < 4 symbols.
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=1 -Zdwarf-version=3 -Cforce-frame-pointers}"

# -Clink-dead-code=off: cargo-fuzz's default -Clink-dead-code ICEs this nightly's rustc
# (region_param_out_of_range in instantiate_and_check_impossible_predicates) on pris's
# 2015-edition generics; sancov instrumentation is unaffected — only dead (unreferenced)
# code drops out of the binary.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SAN $RUST_DEBUG_FLAGS -Clink-dead-code=off"

# libfuzzer-sys compiles its C++ libFuzzer runtime through the `cc` crate (clang), which
# defaults to DWARF-5. rustc's -Zdwarf-version only covers Rust CUs, so pin the C/C++ side
# to DWARF-3 too via CFLAGS/CXXFLAGS.
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# The additive fuzz crate (mayhem/fuzz) hosts the ported pris-fuzz harness; upstream ships
# no fuzz/ directory (the harness came from the previous mayhemheroes integration).
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's pinned toolchain (RUSTUP_TOOLCHAIN above). A `+toolchain` override would
# make rustup try to install another channel into the locked /opt/toolchains/rust.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -s "$CFZ_SANITIZER" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── Test artifacts (project's NORMAL flags — no sanitizer, no --cfg fuzzing) ─────────────
# A SEPARATE target dir keeps the fuzz RUSTFLAGS from leaking into this clean build.
echo "=== building pris test suite (cargo test --no-run, normal flags) ==="
TESTDIR="$SRC/mayhem-build"
mkdir -p "$TESTDIR"
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS CARGO_TARGET_DIR="$TESTDIR/target" \
  cargo test --no-run --message-format=json > "$TESTDIR/test-build.json"

# Record the test executables (lib unit tests + tests/eval.rs) for mayhem/test.sh to RUN.
python3 - "$TESTDIR/test-build.json" "$TESTDIR/test-bins.txt" <<'PY'
import json, sys
bins = []
for line in open(sys.argv[1]):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("reason") == "compiler-artifact" and m.get("executable") \
       and m.get("profile", {}).get("test"):
        bins.append(m["executable"])
open(sys.argv[2], "w").write("\n".join(bins) + "\n")
print("test binaries:", bins)
PY
[ -s "$TESTDIR/test-bins.txt" ] || { echo "ERROR: no test binaries produced" >&2; exit 1; }

# Release `pris` binary for the examples suite (tests/compile_examples.py). Release, not
# debug: modern rustc's debug-assertion unsafe-precondition checks trip on a latent upstream
# harfbuzz-binding slice::from_raw_parts(NULL) in ONE example (raw_string.pris); the release
# binary matches what users run and keeps all 22 upstream examples in the oracle.
echo "=== building release pris binary (for examples oracle) ==="
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS CARGO_TARGET_DIR="$TESTDIR/target" \
  cargo build --release
[ -x "$TESTDIR/target/release/pris" ] || { echo "ERROR: release pris binary missing" >&2; exit 1; }

echo "build.sh complete"
