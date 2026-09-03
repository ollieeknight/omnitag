# omnitag — architecture

Native macOS tag editor. Music, audiobooks, movies, TV. Local library only.
No cloud sync, no streaming, no playback engine.

## Stack decision

Swift 6.4 + SwiftUI (AppKit escape hatches via `NSViewRepresentable`), SwiftPM
multi-module package, Swift Testing, async/await + `@Observable`.

Rejected alternatives:

| Option | Why not |
|---|---|
| Electron | 150 MB baseline, no native file coordination, no AVFoundation, no security-scoped bookmarks. A tag editor is 90% filesystem + binary parsing — the browser is dead weight. |
| React Native macOS | Same bridge cost, worse macOS surface (no `NSTableView`-grade list virtualisation, weak drag-and-drop). |
| Catalyst | iPad idioms leak into a pro Mac app. Wrong ergonomics for batch editing. |
| Rust core + SwiftUI shell | Defensible for the parsers later. Not now: AVFoundation already reads every container we ship in phase 1, and an FFI seam we do not need is exactly the abstraction ponytail refuses to buy. Revisit if we hand-roll FLAC/Vorbis. |

Combine is *not* used. `@Observable` + async sequences cover it; Combine is
legacy surface in a new Swift 6 codebase.

## Project files

`Package.swift` is the source of truth for modules and test targets. `project.yml`
is an xcodegen spec that wraps the app target in a macOS bundle so Xcode can run
it and render Previews; `OmniTag.xcodeproj` is generated from it and gitignored.
Views live in `Sources/OmniTagApp` (the app target) rather than in a package
module precisely so Previews work.

## Modules (SwiftPM targets)

```
MediaCore        domain model + FilenamePattern, no I/O, no framework imports
                 beyond Foundation
TagIO            MediaTagReader facade + per-format readers/writers + key maps
LibraryIndex     folder scan and file typing (persistence: not built yet)
MetadataAPI      protocol MetadataProvider + per-service clients (Audible, Audnexus, OpenLibrary)
EditEngine       batch edit, undo/redo, save orchestration, backups, renaming
OmniTagApp     SwiftUI executable
```

Dependency direction is one way: `App → EditEngine → {TagIO, LibraryIndex, MetadataAPI} → MediaCore`.
Nothing below `App` imports SwiftUI.

## Domain model (MediaCore)

```swift
enum MediaKind { case music, audiobook, book, movie, tvEpisode }

struct MediaItem: Identifiable, Sendable {
    var id: URL                    // stable across in-app renames; URL until external moves require UUID + inode
    var url: URL
    var kind: MediaKind
    var container: ContainerFormat // .mp3 .m4a .m4b .flac .mp4 .mkv .mov .epub .pdf …
    var tags: TagSet
    var chapters: [Chapter]
    var artwork: [Artwork]
}

struct TagSet: Sendable {          // string-keyed, typed accessors on top
    var values: [TagKey: TagValue]
}
```

`TagKey` is an enum with a `.custom(String)` case so a format's exotic frames
survive a round-trip instead of being silently dropped. Round-trip fidelity is
a test invariant, not a nice-to-have.

`Chapter` = `{ start: CMTime-free Duration, title: String, artwork: Artwork? }`.
MediaCore stays framework-free so it is trivially testable.

## Tag I/O

```swift
protocol TagReader  { func read(_ url: URL) throws -> RawTags }
protocol TagWriter  { func write(_ tags: TagSet, to url: URL) throws }
```

Registry maps `ContainerFormat → (reader, writer)`. Adding Ogg later = one file
plus one registry line, no changes anywhere else.

Current backends:
- read: AVFoundation `AVAsset.load(.metadata)` (mp3, m4a, m4b, mp4, mov, wav, aiff); `MatroskaReader` (hand-written EBML walker: Info, Tags, Chapters, cover attachments) for mkv; `EPUBReader` (custom `ZipArchive` + OPF parser) for epub; `PDFReader` (PDFKit) for pdf.
- write: `MPEG4TagWriter` and `MPEG4ChapterWriter` for the MP4 family (m4a/m4b/mp4/mov); `ID3TagWriter` (hand-rolled ID3v2.4) for mp3; `MatroskaTagWriter` (in-place EBML element patch) for mkv; `EPUBTagWriter` (surgical OPF update) for epub; `PDFTagWriter` for pdf.
- flac / ogg / opus write: future phase (hand-rolled Vorbis comment).

### Write safety (non-negotiable)

Every write is: temp file in the same directory → verify by re-reading the temp
→ atomic `replaceItemAt` → original's tag bytes archived to
`~/Library/Application Support/omnitag/backups/<itemID>/<timestamp>.json`.
mkv is the deliberate exception (in-place patch outside Clusters to avoid copying gigabytes).
A crash mid-write can never leave a truncated media file. This is the one place
laziness is banned.

## Metadata APIs

```swift
protocol MetadataProvider {
    var kinds: Set<MediaKind> { get }
    func search(_ q: Query) async throws -> [MetadataCandidate]
}
```

Per kind, an ordered provider list with fallback:
- music: iTunes Search API (no key) → MusicBrainz (rate-limited, 1 req/s, UA required) — not built yet
- audiobook: Audible (catalogue search, ASIN lookup) + Audnexus (ASIN-keyed detail, chapters) ✅
- book: OpenLibrary (search, work/edition lookup) ✅
- movie: TMDB — not built yet
- tv: TMDB → TVmaze — not built yet
- Watchmode: skipped. "Where to watch" is streaming data; app is local-library scope. Not built.

All clients sit behind `URLProtocol`-stubbed tests — no live network in CI.
Offline-first: every feature except *enrich from API* works with the network off.

## Undo/redo

Not `UndoManager`. Domain-level: `EditEngine` holds a stack of steps. A tag
step is a `{ itemID, before, after }` batch; undo re-applies `before` and
re-writes the file. Same mechanism serves both the in-memory grid and the
on-disk revert, so undo after a save actually undoes the save.

A rename is the other kind of step. It already happened on disk — there is no
useful half-renamed state — so undoing one moves the files back. Renaming
re-keys the working set, the saved baseline, the order and both stacks, which is
what lets unsaved edits follow a file to its new name. See `FILENAMES.md`.

## UI

`NavigationSplitView`: sidebar (5 media kinds: music, audiobooks, books, movies, TV) │ item table │
inspector. Table is `Table` with column sets swapped per kind. Batch edit =
multi-select + inspector fields showing `<multiple values>` placeholders,
typing commits to all selected. Mini-transport bar for audio preview and chapter marking.
Full keyboard: ⌘F search, ⌘S write, ⌘Z undo, ⏎ edit, Space quicklook.

## Phases

1. ✅ MediaCore + TagIO read + scan + table UI.
2. ✅ MPEG-4 write path + backups + atomic replace.
3. ✅ EditEngine: batch edit, undo/redo, save; inspector UI.
4. ✅ ID3 read, chapter read, Matroska read, `MediaTagReader` facade.
5. ✅ mp3 write (hand-rolled ID3v2.4), mkv write (in-place element rewrite).
6. ✅ Metadata providers (Audible, Audnexus, OpenLibrary), artwork editing (drop, folder discovery, clipboard paste).
7. ✅ Chapter editing (MPEG-4 chapter writer, inspector studio, wizard diff), ✅ filename↔tag conversion (`FilenamePattern`, `RenamePlan`).
8. flac, ogg/opus.
