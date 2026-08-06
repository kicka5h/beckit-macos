<div align="center">

<img src="App/Assets/Beckit-1024.png" width="128" alt="Beckit">

# Beckit for macOS

A native macOS app for writing books — with GitHub sync, chapter versioning, and PDF export.

</div>

---

This is a ground-up rewrite of [Beckit](https://github.com/kicka5h/beckit-book-editor),
which was a Python app built on Flet. Same features, different foundations: Swift,
SwiftUI, and AppKit, with nothing between the keystroke and the text view.

## Why a rewrite

The Python app worked, but two things could not be fixed from inside it.

**Performance.** Flet drives a Flutter UI over a Python bridge, so every keystroke
crossed a process boundary. The old app's click-to-edit / click-away-to-preview
mode switch was not a design decision — it existed because the toolkit could not
style text while you typed. Here there is one always-live text view, and
restyling after an edit touches only the paragraph you are typing in, so a
120,000-word manuscript costs the same per keystroke as an empty one.

**Appearance.** The old UI was Flutter widgets approximating macOS. This one is
SwiftUI and AppKit, so it inherits the real thing: sidebar, inspector, sheets,
menu bar, Find, spelling, automatic quotes and dashes.

Three other things fell out of the rewrite:

| | Beckit 3.x | Here |
|---|---|---|
| PDF export | Bundled pandoc + TeX Live (hundreds of MB, fragile in CI) | TextKit and Core Graphics, already in macOS |
| GitHub token | Cleartext in `~/Library/Application Support/beckit/config.json` | macOS keychain |
| Version storage | A duplicate folder per version, in the working tree forever | Git commits and tags |

## Design

Built for [Liquid Glass](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/),
the design system introduced with macOS Tahoe. Because the app is compiled
against the macOS 26 SDK, standard controls, the sidebar, the inspector and the
toolbar adopt the material automatically — so most of the work was *removing*
things that fought it, and adopting the explicit APIs where a floating layer is
genuinely the right answer:

- **No opaque panel fills.** Hardcoded backgrounds stop the material sampling
  what is behind it, which is the entire premise. The welcome pane is
  `glassEffect` over a `backgroundExtensionEffect` wash instead of a grey fill.
- **Chrome floats above content.** Word count and sync status are a glass
  capsule over the prose rather than a bar welded under it, so the text column
  runs the full height of the pane.
- **Concentric corners.** Nested containers use `ConcentricRectangle`, so their
  radii stay concentric with the window's rather than being guessed at.
- **Grouped toolbar items.** `ToolbarSpacer(.fixed)` separates actions that
  change the book from toggles that change the view, so they read as two
  controls rather than one undifferentiated capsule.

Glass is used sparingly and never stacked on glass. It marks the layer above the
writing; the writing itself is plain text on the window's own material.

### The mark

An open book whose spine is a pencil — the two things the app is for, sharing
one line. Each page's top edge flows into that side of the pencil and down to
the point, so page and pencil are a single unbroken contour rather than two
shapes stacked together.

It is drawn in code (`Scripts/make-icon.swift`), not stored as artwork, so every
size in the iconset comes from one set of numbers. The `AppMark` view used
inside the app mirrors the same geometry in SwiftUI; the generator is a
standalone script and cannot import app code, so those two are kept in step by
hand — change one and you must change the other.

Two things it does that a static asset cannot:

- **Optical sizing.** A stroke weight that looks elegant at 512pt is under a
  pixel wide at 16pt and renders as a grey smudge. The weight ramps up as the
  canvas shrinks, so the 16pt icon stays legible.
- **Size-dependent detail.** The line across the pencil's sharpened end is
  dropped below 64pt, where the taper is only a few pixels wide and the detail
  would land as a blot.

It is drawn full-bleed, because macOS 26 masks app icons to the system shape
itself — artwork that ships its own rounded rectangle ends up inset twice and
sits visibly small in the Dock.

## Storage format

Beckit 3.x stored every version as its own directory:

```
Chapters/
  Chapter 1/
    v1.0.0/v1.0.0.md
    v1.1.0/v1.1.0.md
```

Which meant a book carried its whole history as duplicated files, and reordering
a chapter renamed every folder after it — losing that chapter's history in the
process.

Here, each section is one file, and its versions are git commits:

```
book.json              ← manifest: title, author, ordered spine, versions
Chapters/the-ferry.md
FrontMatter/dedication.md
BackMatter/epilogue.md
Planning/…             ← outlines and notes, never part of the export
```

The manifest owns order and titles, so **files keep stable names**. Reordering
chapters rewrites one line of JSON and moves nothing, and `git log --follow`
keeps every chapter's history attached across reorders and retitles. Versions
are recorded as tags namespaced per section:
`beckit/<section-uuid>/v1.2.0`.

Opening a 3.x book offers to convert it. The conversion replays every version as
a dated commit, so nothing is lost — the history moves from the filesystem into
git. It is shown to you in full before anything happens, and afterwards Beckit
3.x can no longer read the book.

## Versioning

Saving classifies how much the prose changed and bumps the version itself, so
you never choose between major and minor. The thresholds are carried over from
the Python app (`ChangeClassifier`):

- **none** — under 5 words and under 5% of lines changed
- **major** — headings restructured, word count moved over 20%, or a recurring
  proper noun appeared or disappeared
- **minor** — over 30 words or over 15% of lines changed
- **patch** — anything else

One rule is deliberately *not* a faithful port. The original counted any
capitalised word as a possible character name, so "The", "He" and "She" made
almost every prose edit a major version. Here a word only counts if it appears
mid-sentence at least once.

## Building

Requires macOS 26 and Xcode 26.

```bash
swift test
```

```bash
Scripts/build-app.sh release && open build/Beckit.app
```

SwiftPM builds a bare executable; `Scripts/build-app.sh` wraps it in the bundle
macOS needs to own a window and reach the keychain. There is no `.xcodeproj` to
keep in sync — open `Package.swift` in Xcode if you want the IDE.

To sign in to GitHub you need an OAuth app client ID (not a secret — the device
flow uses no client secret):

```bash
BECKIT_OAUTH_CLIENT_ID=your_client_id Scripts/build-app.sh release
```

## Layout

```
Sources/
  BeckitKit/    Domain: book model, versioning rules, working-tree store,
                word count, markdown blocks, the 3.x importer.
                No UI, no git, no network — fast to test.
  BeckitGit/    The GitRepository protocol, its process-based implementation,
                GitHub device flow, and keychain token storage.
  BeckitPDF/    Book typesetting with TextKit and Core Graphics.
  Beckit/       The SwiftUI app.
Scripts/
  build-app.sh      Wraps the executable into Beckit.app.
  build-libgit2.sh  Builds the vendored git backend.
```

`BeckitKit` deliberately knows nothing about git or AppKit, so the interesting
logic — versioning, import planning, book structure — is testable without a
repository or a window.

## Status

Working: editor, sidebar, chapter and matter CRUD, reorder, auto-versioning,
version history and restore, word counts, PDF export, GitHub device-flow
sign-in, keychain storage, and 3.x import.

Not done yet, in rough order:

1. **`LibGit2Repository`.** Git currently runs through `/usr/bin/git`, which is
   fine for development but on a clean Mac triggers the "install command line
   developer tools" dialog on first sync. `Scripts/build-libgit2.sh` builds the
   vendored library; the backend that uses it is not written.
2. **Repository picker.** Sign-in works and `GitHubClient` can list and create
   repositories, but there is no UI to clone one — you open a local folder.
3. **Planning pane editing.** The tree renders; files are not yet openable.
4. **Scratch pad** and the CLI tools.
5. Signing, notarisation, and a release workflow.

## License

[MIT](LICENSE)
