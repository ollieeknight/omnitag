# omnitag

Native macOS tag editor for a local media library — music, audiobooks, books,
movies, TV. Mp3tag's job, wider scope, no cloud.

## State

Phases 1–7: domain model, folder scan, MPEG-4 read/write, ID3 read/write, **Matroska
read** (hand-written EBML parser) and **write** (in-place EBML patch),
chapter read/write, **book formats** (EPUB read/write via custom `ZipArchive`, PDF via PDFKit),
tag backups, undo/redo, batch editing, and a three-pane SwiftUI
browser. **Metadata Providers** (Audible, Audnexus, OpenLibrary) are
implemented — see `docs/ARCHITECTURE.md`. **Filename ↔ tag conversion** is in:
rename a selection from a `%field%` pattern, or read tags back out of
the names — see `docs/FILENAMES.md`.

Writes are staged: temp file in the same directory, re-read to prove it is
playable, then an atomic swap, with the previous tags archived to JSON first (mkv is patched in place).

## Documentation

| File | For |
|------|-----|
| `AGENTS.md` | entry point for AI agents — read-order and house rules |
| `docs/STATUS.md` | what works today, what does not |
| `docs/ROADMAP.md` | what is next, in startable detail |
| `docs/FORMATS.md` | every tag, and the atom or frame it lives in |
| `docs/ARCHITECTURE.md` | modules, stack rationale, phases |
| `docs/DECISIONS.md` | settled questions and why |
| `docs/DEVELOPMENT.md` | build, test, Xcode, real-media testing |
| `docs/AUDIOBOOKS.md` | Audible/Audnexus APIs, wizard, chapters, playback |
| `docs/BOOKS.md` | EPUB/PDF, ZipArchive, OpenLibrary provider |
| `docs/MOVIES_TV.md` | TMDB provider, Keychain key, episode picker |
| `docs/FILENAMES.md` | the `%field%` pattern language, renaming, parsing names |
| `docs/DISTRIBUTION.md` | Homebrew and code signing |

## Run

```sh
make test    # 242 tests, no network, ~1s
make run     # launch the app
make xcode   # generate and open OmniTag.xcodeproj
make app     # assemble .build/OmniTag.app
make help    # every target
```

Xcode: `Package.swift` defines the modules and tests; `project.yml` (xcodegen)
adds the app-bundle wrapper so ⌘R and SwiftUI Previews work. The `.xcodeproj` is
generated and gitignored — edit `project.yml`, never the project file.

Homebrew: a personal tap with a **formula** (builds from source, so no
Developer ID or notarisation is needed). See `docs/DISTRIBUTION.md`;
template in `packaging/omnitag.rb`.

Point `OMNITAG_REAL_MEDIA` at a folder of your own media to run the suite
against real files too.

`swift run` gives an unbundled app: fine for a smoke test, but NSOpenPanel and
sandboxed folder access want a real bundle. Generate an Xcode project when the
write path lands.

## Supported formats

| Kind | Read (now) | Write |
|---|---|---|
| Music | mp3 (ID3, artwork), m4a, wav, aiff | m4a ✅ (tags, artwork), mp3 ✅ (ID3v2.4, artwork) |
| Audiobook | m4b, incl. chapters, artwork | m4b ✅ (tags, chapters, artwork) |
| Book | epub, pdf | epub ✅ (tags, artwork), pdf ✅ (tags) |
| Video | mp4, mov, m4v | mp4, mov, m4v ✅ (tags, chapters, artwork) |
| Movie / TV (mkv) | tags, chapters, cover attachments | tags ✅ (in-place patch) |
| flac, ogg, opus | scanned, not yet parsed | future phase |

mkv is read by `MatroskaReader`, which memory-maps the file and skips Clusters
by size, and written by `MatroskaTagWriter`, which patches a few hundred bytes in
place rather than remuxing: a 6.5 GB film is retagged in ~32 ms.

## Layout

```
Sources/MediaCore     domain model + FilenamePattern, Foundation only
Sources/TagIO         MediaTagReader facade, AVTagReader, MatroskaReader,
                      EBMLReader, MPEG4TagWriter, MPEG4ChapterWriter, ID3TagWriter,
                      EPUBReader, EPUBTagWriter, PDFReader, PDFTagWriter, key maps, TagBackupStore
Sources/EditEngine    batch edits, undo/redo, save orchestration, RenamePlan
Sources/MetadataAPI   MetadataProvider, AudibleClient, AudnexusClient, OpenLibraryClient
Sources/LibraryIndex  LibraryScanner
Sources/OmniTagApp  SwiftUI shell
Tests/                Swift Testing, real files on disk, zero mocks
AGENTS.md             instructions for LLM agents working here
```
