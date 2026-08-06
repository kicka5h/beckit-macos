#!/bin/bash
# Assembles Beckit.app from the SwiftPM build product.
#
# SwiftPM builds a bare executable; macOS needs it wrapped in a bundle with an
# Info.plist before it can own a window, appear in the Dock, or reach the
# keychain. This does that wrapping, and nothing else — no Xcode project to keep
# in sync, no generated .pbxproj to merge.
#
# Usage: Scripts/build-app.sh [debug|release]

set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build --configuration "$CONFIGURATION"

BIN_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/build/Beckit.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/Beckit" "$APP/Contents/MacOS/Beckit"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

# A client ID supplied by the environment wins over the empty default, so CI can
# inject it without the value ever living in the repository.
if [ -n "${BECKIT_OAUTH_CLIENT_ID:-}" ]; then
    /usr/libexec/PlistBuddy -c \
        "Set :BeckitOAuthClientID $BECKIT_OAUTH_CLIENT_ID" \
        "$APP/Contents/Info.plist"
fi

# Ad-hoc signature. Enough for the keychain and for launching locally; a real
# Developer ID signature and notarisation happen in the release workflow.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || {
    echo "warning: could not sign the bundle; keychain access may prompt" >&2
}

echo "Built $APP"
