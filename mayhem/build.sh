#!/usr/bin/env bash
#
# mayhem/build.sh — build SOF's two libFuzzer targets (IPC3, IPC4) and its host unit tests.
#
# SOF's fuzzer is the Zephyr `native_sim` image built with CONFIG_ARCH_POSIX_LIBFUZZER: the whole
# firmware IPC stack, driven through src/platform/posix/fuzz.c (LLVMFuzzerTestOneInput). It is built
# exactly as scripts/fuzz.sh does (west + app/configs/fuzz_*.conf), with ASan + UBSan switched on
# through Kconfig and made halting. Everything it needs (west venv, pinned Zephyr tree, cmocka) is
# baked into /opt/toolchains by mayhem/deps.sh, so this script runs offline and can be re-run.
#
#   /mayhem/sof-ipc3, /mayhem/sof-ipc4   sanitized libFuzzer binaries (also replay one file: `./sof-ipc4 FILE`)
#   /mayhem/build_ut/                    host cmocka unit tests with normal flags, run by mayhem/test.sh
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

# Zephyr kconfig / compile options mirroring $SANITIZER_FLAGS (an empty value builds with no sanitizers).
conf="prj.conf;boards/native_sim_libfuzzer.conf;configs/fuzz_features.conf"
cmake_san=()
case "$SANITIZER_FLAGS" in
  *address*)
    conf+=";configs/fuzz_asan.conf"
    cmake_san+=(-DCONFIG_ASAN_RECOVER=n) ;;
esac
case "$SANITIZER_FLAGS" in
  *undefined*) conf+=";configs/fuzz_ubsan.conf" ;;
esac

# Native-simulator runner objects (the ASan/libFuzzer side of native_sim) take their debug and recover
# flags from these variables rather than from Zephyr's compile options.
export NSI_DEBUG="$DEBUG_FLAGS"
export NSI_BUILD_C_OPTIONS="-fno-sanitize-recover=all"

# The west workspace holds the pinned Zephyr tree; west resolves the manifest repo (sof -> /mayhem) from
# its cwd, so every west/cmake call below runs from inside it. The LSan-off hook lives in
# mayhem/zephyr-lsan/lsan_off.c (a Zephyr module linked into the runner).
fuzz_build() { # <ipc major: 3|4>
  local ipc="$1" dir="$SRC/build-fuzz-ipc$1"
  rm -rf "$dir"
  (
    cd "$WS"
    unset CC CXX
    export PATH="$TC/zephyr-venv/bin:$PATH"
    export ZEPHYR_TOOLCHAIN_VARIANT=host/llvm ZEPHYR_BASE="$WS/zephyr"
    west build -d "$dir" -b native_sim/native/64 "$SRC/app" -o="-j$MAYHEM_JOBS" -- \
      -DCONF_FILE="$conf;configs/fuzz_IPC${ipc}_features.conf" \
      -DCONFIG_IPC_MAJOR_"$ipc"=y \
      "${cmake_san[@]}" \
      -DEXTRA_CFLAGS="${SANITIZER_FLAGS:+-fno-sanitize-recover=all} $DEBUG_FLAGS" \
      -DZEPHYR_EXTRA_MODULES="$SRC/mayhem/zephyr-lsan"
  )
  cp "$dir/zephyr/zephyr.exe" "$SRC/sof-ipc$ipc"
  chmod 755 "$SRC/sof-ipc$ipc"
}

# 1) + 2) the fuzz targets (the project is built sanitized and with DWARF 3 as part of the target).
fuzz_build 3
fuzz_build 4

# 3) host unit tests (cmocka), normal flags. clang rejects pcm_float.c under -Werror, so they use gcc.
rm -rf "$SRC/build_ut"
(
  unset CFLAGS CXXFLAGS LDFLAGS
  CC=gcc CXX=g++ cmake -S "$SRC" -B "$SRC/build_ut" \
    -DBUILD_UNIT_TESTS=ON -DBUILD_UNIT_TESTS_HOST=ON -DINIT_CONFIG=unit_test_defconfig \
    -DCMOCKA_DIRECTORY="$CMOCKA"
  CC=gcc CXX=g++ cmake --build "$SRC/build_ut" -- -j"$MAYHEM_JOBS"
)
