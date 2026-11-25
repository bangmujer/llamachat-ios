#!/usr/bin/env bash
# Build llama.xcframework untuk Mac lokal (opsional — CI melakukan hal yang sama).
# Dijalankan dari root repo llama.cpp yang sudah di-clone di tag v1.0.0,
# ATAU script ini meng-clone-nya sendiri ke /tmp/llama.cpp.
# Output: build-apple/llama.xcframework (di dalam checkout llama.cpp),
# lalu disalin ke ThirdParty/llama.xcframework di repo ini.
set -euo pipefail

TAG="v1.0.0"
SRC="/tmp/llama.cpp"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$SRC"
fi

cd "$SRC"
git rev-parse HEAD
# Hanya ios-device, sesuai keputusan: device arm64 saja, tanpa simulator.
# GGML_METAL=ON dan GGML_METAL_EMBED_LIBRARY=ON adalah default script upstream.
./build-xcframework.sh ios-device

mkdir -p "$(dirname "$0")/../ThirdParty"
cp -R build-apple/llama.xcframework "$(dirname "$0")/../ThirdParty/llama.xcframework"
ls -lh "$(dirname "$0")/../ThirdParty/llama.xcframework"
