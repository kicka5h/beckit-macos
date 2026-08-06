import AppKit
import SwiftUI

/// The app's display face — the wordmark and sheet titles.
///
/// Deliberately narrow in scope. A display face is for the two or three pieces
/// of text that carry the app's character; running it through the whole
/// interface costs legibility everywhere and stops it reading as special
/// anywhere. Body text, sidebars and controls stay on the system font, and
/// prose in the editor stays on its own reading face — see `EditorTheme`.
enum Typography {

    /// Family name of the bundled display font.
    ///
    /// Fonts placed in `App/Fonts/` are copied into
    /// `Beckit.app/Contents/Resources/Fonts` and registered by macOS at launch
    /// through the `ATSApplicationFontsPath` key in Info.plist — so there is no
    /// registration code here, and the font works on a Mac that has never seen
    /// it installed.
    ///
    /// This is the *family* name, which is often not the file name. Run
    /// `Scripts/list-bundled-fonts.sh` after adding a font to see what the
    /// family is actually called.
    static let displayFamily = "Handone"

    /// Whether the bundled display font actually loaded.
    ///
    /// Checked rather than assumed: if the file is missing, misnamed, or the
    /// family name here does not match the one inside the font, the app should
    /// keep working and simply look ordinary.
    static var isDisplayFontAvailable: Bool {
        NSFontManager.shared.availableFontFamilies.contains(displayFamily)
    }

    /// The display face at a given size, falling back to the system serif when
    /// the bundled font is not present.
    ///
    /// Handone sets much smaller than its nominal size — its cap height is
    /// roughly half what the system font gives you at the same value, so a call
    /// here wants a number well above what the same text would take in the
    /// system face. Callers pass optical sizes, not equivalents: the wordmark is
    /// 68 where the system serif was 40.
    static func display(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        guard isDisplayFontAvailable else {
            return .system(size: size, weight: weight, design: .serif)
        }
        // `.custom(_:fixedSize:)` opts out of Dynamic Type scaling, which is
        // wrong for a wordmark that has to sit in a fixed layout; `size:` keeps
        // it scaling with the user's text size preference.
        return .custom(displayFamily, size: size)
    }
}
