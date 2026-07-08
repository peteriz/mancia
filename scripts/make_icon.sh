#!/usr/bin/env bash
# Generate the app icon (Support/Resources/Mancia.icns) from the project logo.
#
# Builds the standard 10-file .iconset (16/32/128/256/512 px, each @1x and @2x)
# from docs/assets/mancia-logo.png with `sips`, then packs it into an .icns with
# `iconutil`. Idempotent: the transient .iconset is built in a scratch dir and
# removed afterwards, so only the committed Mancia.icns changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/docs/assets/mancia-logo.png"
OUT="$ROOT/Support/Resources/Mancia.icns"
ICONSET="$(mktemp -d)/Mancia.iconset"

if [[ ! -f "$SRC" ]]; then
    echo "error: source logo not found at $SRC" >&2
    exit 1
fi

echo "==> building iconset from $SRC"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# name<TAB>pixel-size for each required iconset representation.
# @2x of size N is 2N pixels (e.g. icon_512x512@2x.png is 1024x1024).
gen() {
    local name="$1" size="$2"
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
}
gen icon_16x16.png       16
gen icon_16x16@2x.png    32
gen icon_32x32.png       32
gen icon_32x32@2x.png    64
gen icon_128x128.png     128
gen icon_128x128@2x.png  256
gen icon_256x256.png     256
gen icon_256x256@2x.png  512
gen icon_512x512.png     512
gen icon_512x512@2x.png  1024

echo "==> iconutil -c icns -> $OUT"
iconutil -c icns "$ICONSET" -o "$OUT"

rm -rf "$(dirname "$ICONSET")"
echo "==> built $OUT"
