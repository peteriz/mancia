#!/usr/bin/env bash
# Assemble a release .app bundle from the SPM executable, ad-hoc signed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AI-Edit"
BUNDLE="$ROOT/build/$APP_NAME.app"
BIN_NAME="AIEdit"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"

BIN_PATH="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$BIN_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$BIN_NAME"
cp "$ROOT/Support/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --deep -s - "$BUNDLE"

echo "==> built $BUNDLE"
