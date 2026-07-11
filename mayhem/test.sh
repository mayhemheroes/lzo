#!/usr/bin/env bash
#
# lzo/mayhem/test.sh — REAL self-test oracle. LZO ships its own functional test programs (the
# bundled lzotest/lzotest and minilzo/testmini, plus tests/align + tests/chksum). This oracle does
# an INDEPENDENT clean build of upstream with NORMAL (non-sanitizer) flags into mayhem-tests/, then
# runs LZO's own self-tests:
#
#   * lzotest -mlzo  : round-trips a real file (COPYING) through every LZO method, verifying that
#                      decompress(compress(x)) == x byte-for-byte AND that checksums match.
#   * testmini       : minilzo's bundled self-test (compress a known buffer, decompress, compare).
#   * tests/align    : exercises the alignment helpers the decompressor relies on.
#   * tests/chksum   : verifies adler32/crc32 used to validate decompressed output.
#
# A no-op / "return 0" patch to a decompressor (or any round-trip regression) makes lzotest/testmini
# FAIL the byte-compare. Emits a CTRF (ctrf.io) summary; exit 0 iff every self-test passes.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${MAYHEM_JOBS:=$(nproc)}"
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

# Independent clean build (normal flags, no sanitizers) so the self-test reflects upstream behaviour
# and is isolated from the instrumented in-place build that build.sh produced.
BUILD="$SRC/mayhem-tests"
rm -rf "$BUILD"
mkdir -p "$BUILD"

# Populate $BUILD with a PRISTINE source tree. build.sh ran `./configure` in-place in $SRC with
# $SANITIZER_FLAGS, leaving instrumented Makefiles + config.h there; an out-of-tree (VPATH) build
# whose srcdir is $SRC would inherit that contaminated config and run the self-test under UBSan
# (which trips a benign pointer-arithmetic diagnostic in LZO's own lzo1b_sm.ch). So we materialise a
# clean checkout: prefer `git archive HEAD` (exactly the committed sources, no build artifacts),
# falling back to a copy that is `make distclean`-ed.
if git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
   && git -C "$SRC" archive --format=tar HEAD 2>/dev/null | tar -x -C "$BUILD" 2>/dev/null \
   && [ -x "$BUILD/configure" ]; then
  : # pristine committed tree extracted
else
  cp -a "$SRC"/. "$BUILD"/
  ( cd "$BUILD" && rm -rf .libs src/.libs minilzo/.libs lzotest/.libs tests/.libs \
       && make distclean >/dev/null 2>&1 || true )
fi

# Build with NORMAL optimization flags only — explicitly NOT $SANITIZER_FLAGS — so the oracle
# reflects upstream's own self-test behaviour.
if ! ( cd "$BUILD" && CFLAGS="-O2 -g" ./configure --enable-static --disable-shared \
        >"$BUILD/configure.log" 2>&1 ); then
  echo "FAIL: independent configure failed" >&2
  cat "$BUILD/configure.log" >&2
  emit_ctrf "lzo-selftest" 0 1 0; exit 1
fi

if ! ( cd "$BUILD" && make -j"$MAYHEM_JOBS" >"$BUILD/make.log" 2>&1 ); then
  echo "FAIL: independent build failed" >&2
  tail -40 "$BUILD/make.log" >&2
  emit_ctrf "lzo-selftest" 0 1 0; exit 1
fi

passed=0; failed=0
run_test() {
  local name="$1"; shift
  echo "=== $name: $* ==="
  if "$@"; then
    echo "  PASS $name"; passed=$((passed+1))
  else
    echo "  FAIL $name (exit $?)" >&2; failed=$((failed+1))
  fi
}

LZOTEST="$BUILD/lzotest/lzotest"
TESTMINI="$BUILD/minilzo/testmini"
ALIGN="$BUILD/tests/align"
CHKSUM="$BUILD/tests/chksum"
CORPUS="$SRC/COPYING"

# lzotest round-trips a real file through LZO; this is the core decompress correctness oracle.
if [ -x "$LZOTEST" ] && [ -f "$CORPUS" ]; then
  run_test "lzotest-mlzo" "$LZOTEST" -mlzo -n2 -q "$CORPUS"
else
  echo "  skip lzotest (missing binary or corpus)" >&2; failed=$((failed+1))
fi

# minilzo self-test (compress known buffer, decompress, byte-compare).
if [ -x "$TESTMINI" ]; then
  run_test "minilzo-testmini" "$TESTMINI"
else
  echo "  skip testmini (missing binary)" >&2; failed=$((failed+1))
fi

# Alignment + checksum helpers the decompressor depends on.
[ -x "$ALIGN" ]  && run_test "tests-align"  "$ALIGN"
[ -x "$CHKSUM" ] && run_test "tests-chksum" "$CHKSUM"

echo "=== self-test summary: passed=$passed failed=$failed ==="
if [ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]; then
  emit_ctrf "lzo-selftest" "$passed" 0 0
else
  emit_ctrf "lzo-selftest" "$passed" "$failed" 0; exit 1
fi
