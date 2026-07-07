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

# Sign with a stable identity when available so the Accessibility grant
# survives rebuilds (TCC keys the grant to the code signature; ad-hoc
# signatures change every build). Override with CODESIGN_ID=<name>.
IDENTITY="${CODESIGN_ID:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "AI-Edit Dev Signing"; then
    IDENTITY="AI-Edit Dev Signing"
fi
if [[ -n "$IDENTITY" ]]; then
    echo "==> codesign ($IDENTITY)"
    codesign --force --deep -s "$IDENTITY" "$BUNDLE"
else
    echo "==> codesign (ad-hoc — Accessibility must be re-granted after each rebuild)"
    codesign --force --deep -s - "$BUNDLE"
fi

echo "==> built $BUNDLE"
