#!/usr/bin/env bash
# LinkCore を Embedded Swift で wasm にビルドし、Web の public/ に配置する。
#
# 前提:
#   - Swift 6.4.2 ツールチェーン (swift.org) と、それに対応する Wasm SDK:
#       swift sdk install https://download.swift.org/swift-6.4.2-release/wasm-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz \
#         --checksum 83baca83553f8c443cda7b84800912e6e709c3acd2e7ebf277794ca5836c0da5
#   - macOS で Xcode の swift ではなく swift.org のツールチェーンを使う場合は
#       export TOOLCHAINS=org.swift.642202610261a   (または PATH に .xctoolchain/usr/bin を先頭追加)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${SWIFT_WASM_SDK:-swift-6.4.2-RELEASE_wasm-embedded}"
SWIFT="${SWIFT:-swift}"

echo "[build-wasm] swift: $($SWIFT --version 2>&1 | head -1)"
echo "[build-wasm] sdk  : $SDK"

"$SWIFT" build --package-path "$ROOT" --swift-sdk "$SDK" --product LinkCoreWasm -c release

OUT="$ROOT/web/public/core.wasm"
mkdir -p "$(dirname "$OUT")"   # web/public は core.wasm 以外に中身がなく、git には入っていない
cp "$ROOT/.build/release/LinkCoreWasm.wasm" "$OUT"
echo "[build-wasm] wrote $OUT ($(wc -c < "$OUT") bytes)"
