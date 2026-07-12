#!/usr/bin/env bash
#
# mayhem/test.sh — RUN pris's OWN upstream test suite, prebuilt by mayhem/build.sh:
#   1. every cargo test binary (src/ unit tests: lexer/parser/parser_utils/builtins/png,
#      plus tests/eval.rs — known-answer evaluations asserting interpreter output values);
#   2. the upstream examples suite (tests/compile_examples.py's check: render every
#      examples/*.pris with the release binary), strengthened to a behavioral oracle —
#      each render must produce a non-empty %PDF output file, not just exit 0.
# Emits a CTRF summary and exits non-zero iff any test failed. Does NOT compile anything.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
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

# ── 1. cargo test binaries (built by build.sh with normal flags) ─────────────────────────
BINLIST="$SRC/mayhem-build/test-bins.txt"
if [ ! -s "$BINLIST" ]; then
  echo "ERROR: $BINLIST missing — build.sh should have built the test suite" >&2
  emit_ctrf "cargo-test" 0 1; exit 1
fi
while IFS= read -r bin; do
  [ -n "$bin" ] || continue
  if [ ! -x "$bin" ]; then
    echo "ERROR: test binary $bin missing — build.sh bug" >&2
    FAILED=$(( FAILED + 1 )); continue
  fi
  echo "=== running test binary: $bin ==="
  out="$("$bin" 2>&1)"; rc=$?
  echo "$out" | tail -20
  # Sum every "N passed; M failed; K ignored" result line (one per test binary run).
  read -r p f s <<<"$(printf '%s\n' "$out" | awk '
    /test result:/ { for (i=1;i<=NF;i++) { if ($(i+1)=="passed;") p+=$i; if ($(i+1)=="failed;") f+=$i; if ($(i+1)=="ignored;") s+=$i } }
    END { printf "%d %d %d", p, f, s }')"
  if [ "$(( p + f ))" -eq 0 ] && [ "$rc" -ne 0 ]; then f=1; fi   # crashed before reporting
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; fi             # honest on weird exits
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); SKIPPED=$(( SKIPPED + s ))
done < "$BINLIST"

# ── 2. upstream examples suite (tests/compile_examples.py, behavioral) ───────────────────
# pris writes <input>.pdf NEXT TO the input file; /mayhem is mounted read-only during
# Mayhem coverage collection, so render in a /tmp copy of examples/ (scratch → /tmp always).
PRIS_BIN="$SRC/mayhem-build/target/release/pris"
if [ ! -x "$PRIS_BIN" ]; then
  echo "ERROR: $PRIS_BIN missing — build.sh should have built the release binary" >&2
  FAILED=$(( FAILED + 1 ))
else
  WORK="$(mktemp -d /tmp/pris-examples.XXXXXX)"
  cp -r "$SRC/examples/." "$WORK/"
  for f in "$WORK"/*.pris; do
    name="$(basename "$f")"
    pdf="${f%.pris}.pdf"; rm -f "$pdf"
    if "$PRIS_BIN" "$f" >/dev/null 2>&1 \
       && [ -s "$pdf" ] \
       && head -c4 "$pdf" | grep -q '%PDF'; then
      echo "OK $name"; PASSED=$(( PASSED + 1 ))
    else
      echo "FAILED $name (no valid PDF produced)"; FAILED=$(( FAILED + 1 ))
    fi
  done
  rm -rf "$WORK"
fi

emit_ctrf "cargo-test+examples" "$PASSED" "$FAILED" "$SKIPPED"
