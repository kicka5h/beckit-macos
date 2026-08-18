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

### Type

Display text — the wordmark and sheet titles — uses the system font, tightened
slightly. On macOS that is the cleanest modern option available and the only one
that comes with optical sizing, the full weight range, and correct rendering in
every locale and accessibility setting. Nothing is bundled, so there is no font
to redistribute or licence.

`.displayText(size:)` sets the face and tracks it at `size * -0.018`. Type set
large needs less space between letters than the same face set small; the system
font's default spacing is tuned for body copy, and left alone at 44pt a wordmark
reads loose and unresolved.

Scope is deliberately narrow. A display treatment carries the two or three pieces
of text that give the app its character; applying it across the interface costs
legibility everywhere and stops it reading as special anywhere. Controls,
sidebars and body text use the default styles, and prose in the editor has its
own reading face.

### The mark

An open book whose spine is a pencil, **traced from the reference artwork
itself** rather than redrawn by eye. `Scripts/trace-reference.swift` reads the
source PNG and extracts contours from the pixels:

1. Build a coverage field — how much ink each pixel holds. The source is
   antialiased, so the field is smooth and its half-way contour lands *between*
   pixels rather than on them.
2. Marching squares at half coverage, interpolating along every cell edge, so
   the trace is sub-pixel accurate instead of stair-stepped.
3. Stitch the segments into closed loops.
4. Simplify with Douglas–Peucker, dropping the points that carry no shape
   without moving the curve.
5. Normalise into a 1024-unit design space, centred.

The result is written to `Sources/Beckit/Views/MarkGeometry.swift` and compiled
into **both** the app and the icon generator, so the mark in the window and the
icon in the Dock are the same contours. Nothing is kept in step by hand.

Contours are filled with the even-odd rule, which makes the holes in the
artwork holes without any special handling.

Two things this does that a static asset cannot:

- **Emboldening at small sizes.** Line art is the hard case for an app icon: a
  stroke that looks elegant at 512pt falls under a pixel at 16pt and antialiases
  into pale grey. Stroking the filled outline grows every edge outward by half
  the line width, thickening the mark uniformly without touching the geometry.
  The amount is stated in pixels, because the problem is a pixel problem —
  expressing it as a fraction of the canvas is exactly what hides it.
- **One source of truth.** Retracing a new reference regenerates the geometry
  for the icon and the app together.

It is drawn full-bleed, because macOS 26 masks app icons to the system shape
itself — artwork that ships its own rounded rectangle ends up inset twice and
sits visibly small in the Dock.

> The reference artwork is a third-party icon. Check its licence before shipping
> the app publicly, or commission a mark of your own; the tracer will regenerate
> everything from whatever PNG you point it at.

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

GitHub sign-in works out of the box: the OAuth app's client ID is committed in
`App/Info.plist`. That is deliberate rather than an oversight — device flow is
designed for public clients that cannot keep a secret, so GitHub issues no
client secret for it and the ID ships inside every copy of the binary anyway.

A fork wanting its own OAuth app can override it without touching source:

```bash
BECKIT_OAUTH_CLIENT_ID=your_client_id Scripts/build-app.sh release
```

If you register your own, tick **Enable Device Flow** in the app's settings on
GitHub. It is off by default, it lives on a different screen from the one where
you register the app, and without it sign-in fails with `device_flow_disabled`.

Sign-in requests the `repo` scope, which covers private book repositories. That
is broad — it grants read/write to every repository the account can reach. A
GitHub App with per-repository access would be narrower, at the cost of a more
involved install flow.

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
sign-in, keychain storage, 3.x import, and git through bundled libgit2.

Not done yet, in rough order:

1. **Repository picker.** Sign-in works and `GitHubClient` can list and create
   repositories, but there is no UI to clone one — you open a local folder.
2. **Planning pane editing.** The tree renders; files are not yet openable.
3. **Scratch pad** and the CLI tools.
4. Signing, notarisation, and a release workflow.

## Git

Git is libgit2, linked into the app. Nothing shells out.

That is the whole point: `/usr/bin/git` on a Mac without the Xcode command line
tools is a stub that pops the "install command line developer tools" dialog, and
a writer opening their book should never meet it. `otool` on the built binary
shows no libgit2 dylib and nothing outside the system frameworks.

`Scripts/build-libgit2.sh` builds it — static, universal, TLS through
SecureTransport, SSH off — and writes `Vendor/libgit2.xcframework`, including
the module map SwiftPM needs to import the C headers. That xcframework is
committed (5MB) so a clone builds with `swift build` and no cmake. Rebuild it
against a different version with `Scripts/build-libgit2.sh v1.9.1`.

Both backends live behind the `GitRepository` protocol, and
`BackendParityTests` runs one suite against both — `SystemGitRepository`, which
is git itself, as the reference, and `LibGit2Repository`, which ships.
Divergence between them is a bug in the new one by definition. That suite has
already earned its keep: it caught that git's ref globs are path-component
based, so `refs/tags/beckit/*` never matched Beckit's two-deep version tags,
and that neither backend was pushing tags at all — which would have left a
second machine with no version history.

## License

[MIT](LICENSE)
