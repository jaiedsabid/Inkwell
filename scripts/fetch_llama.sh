#!/bin/bash
# Downloads the pinned llama.cpp framework (the local model engine) into Vendor/, checking its SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=b12167
SHA256=0af08b3039082b1575e6928063636eeb20d80cb5a389b26e37a36bc496a1066e
DEST=Vendor/llama.xcframework
if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ]; then exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Downloading llama.cpp ${VERSION}..."
curl -fsSL -o "$TMP/llama.zip" "https://github.com/ggml-org/llama.cpp/releases/download/$VERSION/llama-$VERSION-xcframework.zip"
echo "$SHA256  $TMP/llama.zip" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch for llama.cpp $VERSION" >&2; exit 1; }
unzip -q "$TMP/llama.zip" -d "$TMP/x"
rm -rf "$DEST" && mkdir -p Vendor
mv "$TMP/x/build-apple/llama.xcframework" "$DEST"
echo "$VERSION" > "$DEST/.version"
echo "llama.cpp $VERSION ready in $DEST"
