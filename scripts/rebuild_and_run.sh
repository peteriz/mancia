#!/usr/bin/env bash
# Quit Mancia, clear its stale Accessibility grant, rebuild the app, and relaunch it.
#
# Ad-hoc signed builds get a new code signature each time, so macOS keeps showing
# the old Accessibility grant as enabled while it no longer applies. Resetting it
# makes the next shortcut press prompt for a fresh grant.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Mancia"
BUNDLE="$ROOT/build/$APP_NAME.app"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$ROOT/Support/Info.plist")"

wait_for_exit() {
    for _ in {1..20}; do
        pgrep -x "$APP_NAME" >/dev/null || return 0
        sleep 0.1
    done
    return 1
}

if pgrep -x "$APP_NAME" >/dev/null; then
    echo "==> quitting $APP_NAME"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
    if ! wait_for_exit; then
        echo "==> forcing $APP_NAME to quit"
        kill -TERM $(pgrep -x "$APP_NAME") 2>/dev/null || true
        wait_for_exit || kill -KILL $(pgrep -x "$APP_NAME") 2>/dev/null || true
    fi
fi

echo "==> resetting Accessibility permission for $BUNDLE_ID"
tccutil reset Accessibility "$BUNDLE_ID" || true

"$ROOT/scripts/make_app.sh"

echo "==> launching $BUNDLE"
open "$BUNDLE"
