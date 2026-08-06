#!/bin/bash
# Prints the family, full and PostScript names of every font in App/Fonts.
#
# A font's family name is frequently not its file name — handone.thin.otf calls
# itself "Handone" — and `Typography.displayFamily` needs the family, not the
# file. Run this after dropping a font in, and use the family it reports.
#
# Usage: Scripts/list-bundled-fonts.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FONTS="$ROOT/App/Fonts"

if [ ! -d "$FONTS" ] || [ -z "$(ls -A "$FONTS" 2>/dev/null)" ]; then
    echo "No fonts in App/Fonts."
    exit 0
fi

TOOL="$(mktemp -d)/names"
cat > "$TOOL.swift" <<'SWIFT'
import AppKit
import CoreText

@main
struct Names {
    static func main() {
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(filePath: path) as CFURL
            guard let descriptors =
                CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor]
            else {
                print("\(path): could not be read as a font")
                continue
            }
            print(URL(filePath: path).lastPathComponent)
            for descriptor in descriptors {
                let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
                print("  family:     \(CTFontCopyFamilyName(font) as String)")
                print("  full:       \(CTFontCopyFullName(font) as String)")
                print("  postScript: \(CTFontCopyPostScriptName(font) as String)")
                print("  glyphs:     \(CTFontGetGlyphCount(font))")
            }
        }
    }
}
SWIFT

swiftc -parse-as-library -o "$TOOL" "$TOOL.swift"
"$TOOL" "$FONTS"/*
