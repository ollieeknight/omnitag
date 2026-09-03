# Decisions

Why things are the way they are. Each entry is settled: revisit only with new
information, not with a fresh opinion.

## Swift + SwiftUI + SwiftPM, not Electron/RN/Catalyst

A tag editor is filesystem access plus binary parsing plus a dense table. The
browser is dead weight, and Electron gets no AVFoundation, no file coordination,
no security-scoped bookmarks. Catalyst brings iPad idioms to a pro Mac app.
Considered and rejected: a Rust core behind FFI — defensible once we hand-roll
several parsers, unjustified while AVFoundation covers most containers.

## No third-party dependencies

Zero today. Every parser and writer (MPEG-4 via AVFoundation, EBML and ID3v2.4
by hand, EPUB via custom `ZipArchive`, PDF via PDFKit) has been cheaper and
cleaner than the integration cost of a library. Adding a dependency is allowed;
doing it silently is not.

## Not Combine

`@Observable` plus async/await covers every case in this app. Combine is legacy
surface in a Swift 6 codebase.

## Writes are staged, verified, then swapped

Temp file in the same directory → re-read it to prove it is playable → atomic
`replaceItemAt` → previous tags archived as JSON in Application Support. Slower
and more code than writing in place, deliberately. This is the one place where
the paranoid version is the correct version: the alternative is a truncated
media file the user cannot get back. (Matroska is the deliberate exception:
in-place element rewrite outside Clusters avoids rewriting multi-gigabyte film files).

## Lossless round-trips are an invariant, not a nice-to-have

Unknown atoms and frames become `TagKey.custom` and are written back. The
developer's Audible m4b carries a multi-kilobyte base64 blob and three private
atoms; a tagger that silently drops them is a tagger that destroys data.

## Undo is domain-level, not `UndoManager`

`EditEngine` keeps a stack of before/after batches. One ⌘Z undoes an edit across
200 files, and undo *after* a save rewrites the files — one mechanism for both,
which `UndoManager` would not have given us.

## Matroska target levels are honoured

A `TITLE` at level 70 names the series, at level 50 the episode. Ignoring this is
why so many tools label every episode "Twin Peaks". Tags aimed at a TrackUID are
ignored entirely — that is mkvmerge's statistics, not metadata.

## Homebrew: formula, not cask

A cask ships a prebuilt `.app`, which is downloaded, which is quarantined, which
needs a paid Developer ID and notarisation. A formula builds from source on the
user's machine: nothing quarantined, ad-hoc signing sufficient, free. Cost is a
full Xcode toolchain on the build machine. Revisit only if the app ships to
people who do not have one. See `DISTRIBUTION.md`.

## Xcode project is generated, not committed

`project.yml` (xcodegen) is the spec; `OmniTag.xcodeproj` is disposable and
gitignored. `Package.swift` stays the source of truth for modules and tests, so
the two front doors cannot drift.

## Test fixtures are generated, never committed

`afconvert` builds silent audio and `EBMLBuilder` builds Matroska by hand, both
carrying real Twin Peaks metadata. No copyrighted media in the repo, ever. Real
files are opt-in through `OMNITAG_REAL_MEDIA` — and they have already caught two
bugs the synthetic fixtures could not.

## Out of scope, permanently

Cloud sync, streaming, library server, "where to watch" data
(Watchmode). OmniTag edits tags on local files.
