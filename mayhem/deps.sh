#!/usr/bin/env bash
#
# mayhem/deps.sh — image-build-time (root, online) install of everything mayhem/build.sh needs offline:
#   * a python venv with west + Zephyr's python deps          -> /opt/toolchains/zephyr-venv
#   * a west workspace holding the pinned Zephyr tree         -> /opt/toolchains/zephyr-ws
#   * a pinned build of the thesofproject/cmocka unit-test lib -> /opt/toolchains/cmocka
# Inputs are staged by the Dockerfile in /opt/sof-deps: requirements.txt and manifest/ (west.yml + submanifests/).
set -euo pipefail

TC=/opt/toolchains
WS=$TC/zephyr-ws
VENV=$TC/zephyr-venv
CMOCKA=$TC/cmocka
CMOCKA_REV=a3f23749a5775ba676dd25dc34f52820932be222
STAGE=/opt/sof-deps

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-venv
rm -rf /var/lib/apt/lists/*

python3 -m venv "$VENV"
"$VENV/bin/pip" install --no-cache-dir -r "$STAGE/requirements.txt"
export PATH="$VENV/bin:$PATH"

# west wants the manifest repo to be a real directory inside the workspace; build.sh later swaps it for a
# symlink to /mayhem (the repo copy that is actually built).
mkdir -p "$WS"
cp -r "$STAGE/manifest" "$WS/sof"
(
  cd "$WS"
  west init -l sof
  # Only the Zephyr tree itself is needed for native_sim; the audio/hal modules in west.yml are
  # not referenced by the fuzz configuration, and tomlc99 lives inside /mayhem.
  west update zephyr --narrow --fetch-opt=--depth=1
)
rm -rf "$WS/sof"
ln -s /mayhem "$WS/sof"

src=$(mktemp -d)
git clone https://github.com/thesofproject/cmocka "$src/cmocka"
git -C "$src/cmocka" checkout "$CMOCKA_REV"
cmake -S "$src/cmocka" -B "$src/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-std=gnu99 \
  -DWITH_SHARED_LIB=OFF -DWITH_STATIC_LIB=ON -DWITH_EXAMPLES=OFF \
  -DWITH_POSITION_INDEPENDENT_CODE=OFF -DWITH_TINY_CONFIG=ON
cmake --build "$src/build" -j"$(nproc)"
mkdir -p "$CMOCKA/lib"
cp "$src/build/src/libcmocka-static.a" "$CMOCKA/lib/"
cp -r "$src/cmocka/include" "$CMOCKA/include"
rm -rf "$src"

chown -R 2000:2000 "$WS" "$VENV" "$CMOCKA"
