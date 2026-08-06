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

# Regenerate the icon when either the renderer or the traced geometry has
# changed, so the committed .icns cannot drift from what produces it.
#
# The generator is compiled rather than run as a script because it shares
# MarkGeometry.swift with the app — that sharing is what keeps the Dock icon and
# the in-app mark identical, and a single-file script cannot have it.
GEOMETRY="$ROOT/Sources/Beckit/Views/MarkGeometry.swift"
if [ ! -f "$ROOT/App/Assets/Beckit.icns" ] \
   || [ "$ROOT/Scripts/make-icon.swift" -nt "$ROOT/App/Assets/Beckit.icns" ] \
   || [ "$GEOMETRY" -nt "$ROOT/App/Assets/Beckit.icns" ]; then
    echo "Rendering app icon…"
    TOOL="$(mktemp -d)/make-icon"
    swiftc -parse-as-library -O -o "$TOOL" \
        "$ROOT/Scripts/make-icon.swift" "$GEOMETRY"
    "$TOOL" "$ROOT/App/Assets"
fi
cp "$ROOT/App/Assets/Beckit.icns" "$APP/Contents/Resources/Beckit.icns"

# Bundled fonts. ATSApplicationFontsPath in Info.plist points here, so macOS
# registers whatever lands in this directory when the app launches.
if [ -d "$ROOT/App/Fonts" ] && [ -n "$(ls -A "$ROOT/App/Fonts" 2>/dev/null)" ]; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    cp "$ROOT"/App/Fonts/* "$APP/Contents/Resources/Fonts/"
fi

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
