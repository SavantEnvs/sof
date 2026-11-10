#!/usr/bin/env bash
#
# mayhem/build.sh — build the eq_iir libFuzzer target (mayhem/eq_iir/) and SOF's host and Zephyr unit tests.
#
# The fuzzer runs the eq_iir component (the IIR response blob goes through set_configuration, then audio
# through module_process_sink_src) on the host cmocka scaffold, with ASan + UBSan on the project sources.
# Everything it needs (cmocka, pinned Zephyr tree, west venv) is baked into /opt/toolchains by
# mayhem/deps.sh, so this script runs offline and can be re-run.
#
#   /mayhem/fuzz_eq_iir[-standalone]     sanitized libFuzzer binary / run-once file-input reproducer
#   /mayhem/build_ut/                    host cmocka unit tests with normal flags, run by mayhem/test.sh
#   /mayhem/build_ztest/<suite>/         Zephyr ztest unit suites (test/ztest/unit/**, native_sim, normal flags),
#                                        run by mayhem/test.sh
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS MAYHEM_JOBS

TC=/opt/toolchains
WS=$TC/zephyr-ws
CMOCKA=$TC/cmocka

# Zephyr's build cache and python bytecode go to scratch space, never into the image or $HOME.
export XDG_CACHE_HOME="${TMPDIR:-/tmp}/sof-xdg-cache"
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$XDG_CACHE_HOME"

cd "$SRC"

# 1) + 2) the eq_iir fuzz target and its standalone reproducer: mayhem/eq_iir/ is added to the host unit-test
# scaffold (malloc-backed allocator, so ASan sees every block) through CMAKE_PROJECT_INCLUDE; the project
# sources are built sanitized, DWARF 3. clang rejects pcm_float.c under -Werror, but only the audio_for_eq_iir
# library and the two harness binaries are built here. The UBSan `shift` (shift-base, shift-exponent) and
# `signed-integer-overflow` checks are relaxed: the fixed-point IIR kernel (src/math/iir_df1_generic.c,
# iir_df1_generic.h) shifts negative values, shifts by blob-supplied exponents and overflows its 64-bit
# accumulator on ordinary or arbitrary coefficient sets, which would halt on those inputs before the
# fixed bug (an ASan heap overflow) is reachable. ASan and the other UBSan checks stay halting.
rm -rf "$SRC/build-fuzz-eq-iir"
(
  unset CFLAGS CXXFLAGS LDFLAGS
  export STANDALONE_FUZZ_MAIN="${STANDALONE_FUZZ_MAIN:-/opt/mayhem/StandaloneFuzzTargetMain.c}"
  CC=clang CXX=clang++ cmake -S "$SRC" -B "$SRC/build-fuzz-eq-iir" -G Ninja \
    -DBUILD_UNIT_TESTS=ON -DBUILD_UNIT_TESTS_HOST=ON -DINIT_CONFIG=unit_test_defconfig \
    -DCMOCKA_DIRECTORY="$CMOCKA" -DCMAKE_PROJECT_INCLUDE="$SRC/mayhem/eq_iir/hook.cmake" \
    -DLSAN_OFF_SRC="$SRC/mayhem/eq_iir/lsan_off.c" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS ${SANITIZER_FLAGS:+-fno-sanitize=shift,signed-integer-overflow} -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
  cmake --build "$SRC/build-fuzz-eq-iir" --target fuzz_eq_iir fuzz_eq_iir-standalone -- -j"$MAYHEM_JOBS"
)
cp "$SRC/build-fuzz-eq-iir/fuzz_eq_iir" "$SRC/build-fuzz-eq-iir/fuzz_eq_iir-standalone" "$SRC/"

# 3) host unit tests (cmocka), normal flags. clang rejects pcm_float.c under -Werror, so they use gcc.
rm -rf "$SRC/build_ut"
(
  unset CFLAGS CXXFLAGS LDFLAGS
  CC=gcc CXX=g++ cmake -S "$SRC" -B "$SRC/build_ut" \
    -DBUILD_UNIT_TESTS=ON -DBUILD_UNIT_TESTS_HOST=ON -DINIT_CONFIG=unit_test_defconfig \
    -DCMOCKA_DIRECTORY="$CMOCKA"
  CC=gcc CXX=g++ cmake --build "$SRC/build_ut" -- -j"$MAYHEM_JOBS"
)

# 4) Zephyr ztest unit suites (test/ztest/unit/**/testcase.yaml), normal flags, built for the 32-bit
# native_sim board exactly as upstream's zephyr-unit-tests.yml does (the 64-bit board does not link the
# math suites against libm and crashes the matrix/dct/fft ones). Offline: only the baked Zephyr tree is used.
rm -rf "$SRC/build_ztest"
(
  cd "$WS"
  unset CC CXX CFLAGS CXXFLAGS LDFLAGS
  export PATH="$TC/zephyr-venv/bin:$PATH"
  export ZEPHYR_TOOLCHAIN_VARIANT=host/llvm ZEPHYR_BASE="$WS/zephyr"
  for tc in $(cd "$SRC/test/ztest/unit" && find . -name testcase.yaml | sort); do
    suite=$(dirname "${tc#./}")
    west build -d "$SRC/build_ztest/${suite//\//_}" -b native_sim "$SRC/test/ztest/unit/$suite" -o="-j$MAYHEM_JOBS"
  done
)
