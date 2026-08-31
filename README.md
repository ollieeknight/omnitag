# omnitag

Native macOS tag editor for a local media library — music, audiobooks, movies,
TV. Mp3tag's job, wider scope, no cloud.

## State

Phases 1–4: domain model, folder scan, MPEG-4 read/write, ID3 read, **Matroska
read** (hand-written EBML parser — AVFoundation cannot open mkv at all),
chapter read, tag backups, undo/redo, batch editing, and a three-pane SwiftUI
browser. Artwork editing, metadata providers, mkv/mp3 writing are still to come
— see `docs/ARCHITECTURE.md`.

Writes are staged: temp file in the same directory, re-read to prove it is
playable, then an atomic swap, with the previous tags archived to JSON first.

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
| `docs/DISTRIBUTION.md` | Homebrew and code signing |

## Run

```sh
make test    # 48 tests, no network, ~1s
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

| Kind | Read (now) | Write (phase 2) |
|---|---|---|
| Music | mp3 (ID3), m4a, wav, aiff | m4a ✅, mp3 (phase 5) |
| Audiobook | m4b, incl. chapters | m4b ✅ (chapters phase 4) |
| Video | mp4, mov, m4v | mp4, mov, m4v ✅ |
| Movie / TV (mkv) | tags, chapters, cover attachments | phase 5 |
| flac, ogg, opus | scanned, not yet parsed | phase 5 |

mkv is read by `MatroskaReader`, which memory-maps the file and skips Clusters
by size: a 7 GB film parses in ~30 ms without loading the video.

## Layout

```
Sources/MediaCore     domain model, Foundation only
Sources/TagIO         MediaTagReader facade, AVTagReader, MatroskaReader,
                      EBMLReader, MPEG4TagWriter, key maps, TagBackupStore
Sources/EditEngine    batch edits, undo/redo, save orchestration
Sources/LibraryIndex  LibraryScanner
Sources/OmniTagApp  SwiftUI shell
Tests/                Swift Testing, real files on disk, zero mocks
AGENTS.md             instructions for LLM agents working here
```
