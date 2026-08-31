# AGENTS.md — OmniTag

Entry point for LLM agents. Humans: see `README.md`.

## Start here, every session

Read these before writing anything. They are short and they are current.

| Read | For |
|---|---|
| `docs/STATUS.md` | what works, what does not, right now |
| `docs/ROADMAP.md` | the next task, in enough detail to start cold |
| `docs/FORMATS.md` | where every tag physically lives, per container |
| `docs/ARCHITECTURE.md` | module boundaries and stack rationale |
| `docs/DECISIONS.md` | settled questions — do not re-litigate these |
| `docs/DEVELOPMENT.md` | build, test, Xcode, real-media testing |
| `docs/DISTRIBUTION.md` | Homebrew and signing |

"Read the docs and do X" means: those seven, then X. If X is not in the roadmap,
say where it fits before starting.

When you finish a piece of work, update `STATUS.md` and tick the roadmap entry
**in the same commit**. A stale STATUS is worse than none — the next session
believes it.

## What this is

Native macOS tag editor for a local media library: music, audiobooks, movies,
TV. Mp3tag's job, wider scope. Offline-first. No cloud sync, no streaming, no
playback engine, no library server.

Swift 6.4, SwiftUI, SwiftPM, macOS 15+. Zero third-party dependencies.

## Non-negotiables

1. **Never corrupt a user's media.** Every write stages to a sibling temp file,
   re-reads it to prove it is playable, then `replaceItemAt`. Previous tags are
   archived to `TagBackupStore` first. Tempted to write in place to save a copy?
   Don't.
2. **Tags round-trip losslessly.** Unknown atoms and frames become
   `TagKey.custom` and are written back. Dropping one is a bug, not a limitation.
3. **Reader and writer share one key table per format** (`MPEG4KeyMap`,
   `ID3KeyMap`, `MatroskaKeyMap`). Never add a key to one side only — that is how
   "my edit vanished on save" happens. Go through `MediaTagReader` /
   `MediaTagWriter`, never a concrete backend: they are what route mkv away from
   AVFoundation and mp3 to the ID3 writer.
4. **Offline is the default path.** Providers enrich; nothing depends on them.
   No test may touch the network.
5. **TDD.** Test first, watch it fail, then implement.
6. **Never write to the developer's real media in a test.** Copy to a temp
   directory first. `~/Desktop/tp` holds their Twin Peaks files.

## Layout

```
Sources/MediaCore     domain model. Foundation only — no AVFoundation, no SwiftUI
Sources/TagIO         MediaTagReader / MediaTagWriter (facades), AVTagReader,
                      MatroskaReader, EBMLReader, MPEG4TagWriter, ID3TagWriter,
                      ID3v2, key maps, TagBackupStore
Sources/EditEngine    TagEdit, EditEngine (batch + undo/redo), FileTagWriter
Sources/LibraryIndex  LibraryScanner
Sources/OmniTagApp    SwiftUI shell (views live here so Previews work)
Tests/                Swift Testing
Package.swift         source of truth for modules and tests
project.yml           xcodegen spec for the app-bundle wrapper only
```

Dependency direction is one way:
`App → EditEngine → {TagIO, LibraryIndex} → MediaCore`. Nothing below `App`
imports SwiftUI. An import that reverses this is a review-blocking change.

## Commands

```sh
make test      # swift test — must be green before you claim anything works
make run       # launch the app
make xcode     # generate + open OmniTag.xcodeproj (gitignored, disposable)
make xcbuild   # build the app target as Xcode does
make xctest    # run the suite through the Xcode scheme
make app       # assemble .build/OmniTag.app
make install   # symlink it into /Applications
make lint      # warnings-as-errors

OMNITAG_REAL_MEDIA=~/Desktop/tp make test   # plus real-file assertions
```

`XcodeBuildMCP` tools may be available; if the server fails to connect, use the
`make xcbuild` / `make xctest` targets instead of reporting the capability
missing. See `docs/DEVELOPMENT.md`.

## Testing rules

- Swift Testing (`@Test`, `#expect`), not XCTest. Do not add XCTest.
- Fixtures are **generated**, never committed: `afconvert` for audio,
  `EBMLBuilder` for Matroska, both tagged through the production writer.
  Copyrighted media must never enter this repo.
- The fixture library is Twin Peaks (`Tests/TagIOTests/TwinPeaks.swift`):
  Badalamenti's theme (music), *The Secret Diary of Laura Palmer* (audiobook,
  chapters), *Fire Walk with Me* (movie), S01E01 *Northwest Passage* (TV).
  New format support means a new fixture there.
- No mocks for the filesystem. Write real files to a temp directory.
- A genuine unimplemented gap may be `withKnownIssue`, never a deleted assertion.

## Skills to use

Process skills first; they set the approach.

| Situation | Skill |
|---|---|
| Any turn in this repo | `caveman` (prose), `ponytail` (code) — both stay on |
| Before a feature | `superpowers:brainstorming`, then `superpowers:writing-plans` |
| Executing a written plan | `superpowers:executing-plans` |
| Writing any code | `superpowers:test-driven-development` or `mattpocock-skills:tdd` |
| Something broken | `superpowers:systematic-debugging`, `mattpocock-skills:diagnosing-bugs` |
| Before claiming done | `superpowers:verification-before-completion` |
| Any Apple/TMDB/Audnexus API question | `find-docs` (`ctx7`). Never answer from memory |
| Module or seam design | `mattpocock-skills:codebase-design`, `domain-modeling` |
| Reviewing a diff | `mattpocock-skills:code-review`, `ponytail-review`, `caveman-review` |
| Tracking deferred shortcuts | `ponytail-debt` (harvests `ponytail:` comments) |
| SwiftUI state/layout/scroll work | `swiftui`, `layout`, `navigation-patterns` |
| Icons, type, glass, HIG | `sf-symbols`, `typography`, `liquid-glass`, `ui-review` |
| Accessibility pass | `accessibility-audit` |
| Swift idiom check | `coding-best-practices` |

Not applicable: `run-simulator`, `run-device`, `ios-dev-workflow` — iOS only.
This is a Mac app; use `make run` or the Xcode scheme.

## Conventions

- `ponytail:` comments mark deliberate shortcuts and name the upgrade trigger.
  Leave them; harvest with `ponytail-debt`. Do not silently "fix" them.
- Doc comments explain *why*. No comment that restates the line below it.
- British English in prose. Conventional commit prefixes (`feat:`, `fix:`,
  `refactor:`, `docs:`), body in plain English.
- Never hand-edit `OmniTag.xcodeproj`; change `project.yml` and regenerate.
- `MediaTagReader.canRead` / `canWrite` is the single source of truth for what
  the app supports. Update it in the same commit as any new backend, and check
  the inspector's read-only warning still reads correctly.
