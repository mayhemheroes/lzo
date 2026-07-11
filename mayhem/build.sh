#!/usr/bin/env bash
#
# lzo/mayhem/build.sh — build the LZO decompressor fuzz harness (lzo_decompress_fuzzer) as a
# sanitized libFuzzer target (+ a standalone run-once reproducer).
#
# Fuzzed surface: LZO's SAFE decompressors (lzo1{b,c,f,x,y,z}_decompress_safe + lzo2a_decompress_safe).
# The harness (mayhem/harnesses/lzo_decompress_fuzzer.c, ported from the OSS-Fuzz lzo project) feeds the
# raw input as a compressed stream into one of those bounds-checked decompressors (selected by
# size % 7) and asserts — via ASan/UBSan — that nothing writes past the 256KB output block.
#
# We build liblzo2 ITSELF from the upstream autotools tree WITH $SANITIZER_FLAGS + -fsanitize=
# fuzzer-no-link, so the decompressor code (not just the harness) is instrumented. $LIB_FUZZING_ENGINE
# is linked only into the libFuzzer harness; the standalone reproducer links $STANDALONE_FUZZ_MAIN.
#
# Build contract comes from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/OUT/
# STANDALONE_FUZZ_MAIN. Outputs land in $OUT (=/mayhem). NO upstream file is modified.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${OUT:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE SRC OUT STANDALONE_FUZZ_MAIN MAYHEM_JOBS

# Coverage instrumentation for liblzo2 so the fuzzer sees decompressor edges. (The libFuzzer target
# also gets -fsanitize=fuzzer from $LIB_FUZZING_ENGINE; the standalone reproducer does not — so build
# the library with -fsanitize=fuzzer-no-link to keep BOTH link forms working.)
COV="-fsanitize=fuzzer-no-link"

cd "$SRC"
HARNESS_DIR="$SRC/mayhem/harnesses"
mkdir -p "$OUT"

# ── 1) Build liblzo2 from the upstream autotools tree WITH sanitizers ─────────────────────────────
# Instrument the decompressor code itself. configure/make build a static src/.libs/liblzo2.a.
export CFLAGS="${CFLAGS:-} $SANITIZER_FLAGS $DEBUG_FLAGS $COV"
# Use the shipped ./configure (it exists in the 2.10 mirror); --enable-static gives us the .a.
./configure --enable-static --disable-shared
make -j"$MAYHEM_JOBS"

LIBLZO2="$SRC/src/.libs/liblzo2.a"
[ -f "$LIBLZO2" ] || { echo "ERROR: $LIBLZO2 not built" >&2; exit 1; }

INC="-I$SRC/include -I$SRC/include/lzo"

# ── 2) Build the harness twice: libFuzzer (-> $OUT/lzo_decompress_fuzzer) + standalone reproducer ─
harness=lzo_decompress_fuzzer

# libFuzzer target (links the fuzzing engine; liblzo2 is the instrumented library under test)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
    "$HARNESS_DIR/$harness.c" $LIB_FUZZING_ENGINE \
    "$LIBLZO2" \
    -o "$OUT/$harness"

# standalone reproducer (no libFuzzer runtime; reads one input file per invocation)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $COV $INC \
    "$HARNESS_DIR/$harness.c" "$STANDALONE_FUZZ_MAIN" \
    "$LIBLZO2" \
    -o "$OUT/$harness-standalone"

echo "built $harness (+ standalone)"
echo "build.sh complete:"
ls -la "$OUT/$harness" "$OUT/$harness-standalone" 2>&1 || true
