#!/usr/bin/env bash
# Package build/Mancia.app into a drag-to-install DMG.
#
# Builds (and signs) the release app via make_app.sh, then wraps it in a DMG
# whose window shows Mancia.app next to an /Applications drop target. Prefers
# the community `create-dmg` tool for the classic layout when a working copy is
# on PATH; otherwise falls back to a plain `hdiutil` staging flow. The result is
# build/Mancia-<version>.dmg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Mancia"
APP="$ROOT/build/$APP_NAME.app"
ICNS="$ROOT/Support/Resources/Mancia.icns"

echo "==> building release app (scripts/make_app.sh)"
"$ROOT/scripts/make_app.sh"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found after make_app.sh" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Support/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG="$ROOT/build/${APP_NAME}-${VERSION}.dmg"
rm -f "$DMG"

# Prefer the community create-dmg tool, but only if it actually runs and speaks
# the flag dialect we rely on (--app-drop-link). A broken or differently-flavored
# create-dmg on PATH falls through to the hdiutil path below.
if command -v create-dmg >/dev/null 2>&1 && create-dmg --help >/dev/null 2>&1 \
    && create-dmg --help 2>&1 | grep -q -- '--app-drop-link'; then
    echo "==> packaging with create-dmg"
    CDMG_ARGS=(
        --volname "$APP_NAME"
        --window-size 540 380
        --icon-size 128
        --icon "$APP_NAME.app" 140 190
        --app-drop-link 400 190
    )
    if [[ -f "$ICNS" ]]; then
        CDMG_ARGS+=(--volicon "$ICNS")
    fi
    # --no-internet-enable is deprecated/removed in newer create-dmg; only pass
    # it when this build advertises it.
    if create-dmg --help 2>&1 | grep -q -- '--no-internet-enable'; then
        CDMG_ARGS+=(--no-internet-enable)
    fi
    # create-dmg exits non-zero if it cannot bless the disk (harmless), so guard.
    if create-dmg "${CDMG_ARGS[@]}" "$DMG" "$APP"; then
        echo "==> built $DMG (create-dmg)"
        exit 0
    fi
    echo "==> create-dmg failed; falling back to hdiutil"
    rm -f "$DMG"
else
    echo "==> create-dmg unavailable/unsupported; using hdiutil"
fi

# hdiutil fallback: stage the app beside an /Applications symlink and compress.
STAGE="$(mktemp -d)/$APP_NAME"
mkdir -p "$STAGE"
echo "==> staging app + Applications shortcut"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
# Best-effort volume icon; drag-install works with or without it.
if [[ -f "$ICNS" ]] && command -v SetFile >/dev/null 2>&1; then
    cp "$ICNS" "$STAGE/.VolumeIcon.icns"
    SetFile -a C "$STAGE" 2>/dev/null || true
fi

echo "==> hdiutil create $DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$(dirname "$STAGE")"
echo "==> built $DMG (hdiutil)"
