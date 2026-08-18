import SwiftUI

/// Display styling for the app's wordmark and sheet titles.
///
/// The face is the system font. On macOS that is the cleanest modern option
/// available and the only one that comes with optical sizing, the full weight
/// range, and correct rendering in every locale and accessibility setting — and
/// it needs nothing bundled, so there is no font to redistribute or licence.
///
/// Scope is deliberately narrow. A display treatment carries the two or three
/// pieces of text that give the app its character; applying it across the
/// interface costs legibility everywhere and stops it reading as special
/// anywhere. Controls, sidebars and body text use the default styles, and prose
/// in the editor has its own reading face — see `EditorTheme`.
extension View {

    /// The app's display treatment at a given size.
    ///
    /// Tracking is tightened in proportion to the size. Type set large needs
    /// less space between letters than the same face set small — the system
    /// font's default spacing is tuned for body copy, and left alone at 44pt a
    /// wordmark reads loose and unresolved.
    func displayText(size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight))
            .tracking(size * -0.018)
    }
}
