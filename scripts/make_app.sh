#!/usr/bin/env bash
# Assemble a release .app bundle from the SPM executable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Mancia"
BUNDLE="$ROOT/build/$APP_NAME.app"
BIN_NAME="Mancia"
SWIFT="$ROOT/scripts/swift.sh"

echo "==> swift build -c release"
"$SWIFT" build -c release --package-path "$ROOT"

BIN_PATH="$("$SWIFT" build -c release --package-path "$ROOT" --show-bin-path)/$BIN_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$BIN_NAME"
cp "$ROOT/Support/Info.plist" "$BUNDLE/Contents/Info.plist"
cp -R "$ROOT/Support/Resources/." "$BUNDLE/Contents/Resources/"
cp "$ROOT/docs/assets/mancia-logo.png" "$BUNDLE/Contents/Resources/mancia-logo.png"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Sign with a stable identity when available so the Accessibility grant
# survives rebuilds (TCC keys the grant to the code signature; ad-hoc
# signatures change every build). Override with CODESIGN_ID=<name>.
IDENTITY="${CODESIGN_ID:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Mancia Dev Signing"; then
    IDENTITY="Mancia Dev Signing"
fi
if [[ -n "$IDENTITY" ]]; then
    CODESIGN_FLAGS_ARRAY=()
    if [[ -n "${CODESIGN_FLAGS:-}" ]]; then
        read -r -a CODESIGN_FLAGS_ARRAY <<< "$CODESIGN_FLAGS"
    elif [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
        CODESIGN_FLAGS_ARRAY=(--options runtime)
    fi
    echo "==> codesign ($IDENTITY)"
    if (( ${#CODESIGN_FLAGS_ARRAY[@]} > 0 )); then
        codesign --force --deep "${CODESIGN_FLAGS_ARRAY[@]}" -s "$IDENTITY" "$BUNDLE"
    else
        codesign --force --deep -s "$IDENTITY" "$BUNDLE"
    fi
else
    if [[ "${REQUIRE_SIGNING:-0}" == "1" ]]; then
        echo "error: no signing identity found; set CODESIGN_ID for release builds" >&2
        exit 1
    fi
    echo "==> codesign (ad-hoc — Accessibility must be re-granted after each rebuild)"
    codesign --force --deep -s - "$BUNDLE"
fi

echo "==> built $BUNDLE"
