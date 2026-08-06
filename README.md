<div align="center">

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
