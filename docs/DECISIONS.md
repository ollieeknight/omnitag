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

## Acoustic fingerprinting: deferred, and it costs the dependency rule

AcoustID/Chromaprint identification is the real differentiator behind Picard
and Tag Editor 2's "Rapid Tagging", and it is the one thing that genuinely
rescues a badly tagged music library — filename and tag search cannot.

Deferred rather than planned, because it cannot be done under the rule above:
Chromaprint is a C library, there is no Swift port, and a fingerprint
algorithm is not something to hand-roll from a paper. Taking it means taking
this project's **first third-party dependency**, plus an API key and a
network call in the identification path.

That is an architectural decision, not a backlog item, which is why it lives
here and not in `ROADMAP.md`. Revisit only if music becomes OmniTag's primary
use and the throughput work in `ROADMAP.md` item 2 has not made manual
matching cheap enough. See `COMPETITION.md`.

## Sidecar files are not our job

tinyMediaManager and friends write `.nfo` files, `-fanart.jpg` artwork sets
and Plex/Jellyfin folder layouts *beside* media. That is media-server
curation: it owns the shape of your library's folders, and it exists because
those servers read sidecars rather than tags.

OmniTag writes metadata **inside** the file, losslessly and reversibly. A
file tagged here is correct wherever it goes, with no second file to keep in
sync and no folder convention to obey. Generating sidecars would pull the app
towards the "library server" role already ruled out below, and would mean
owning a layout OmniTag deliberately does not manage.

Plex and Jellyfin both read embedded tags. That is the integration.

(Filename *presets* matching those servers' conventions are a different
thing, and fine — `FilenamePattern` already renders any naming scheme.)

## Actions, not a scripting language

`ROADMAP.md` item 2d adds saved, ordered, user-authored edit recipes. It
deliberately stops short of an expression language.

Picard has the most powerful scripting in the category and a matching share
of its support traffic; Mp3tag's Action Groups and Meta's derive/compose
serve the same need at a fraction of the conceptual cost. The 2024–2026
evidence in `COMPETITION.md` says automation must be **user-authorable**, not
that it must be Turing-complete.

A small expression syntax is allowed later, but only where users already
think in transforms (compose a tag, derive a tag, a conditional rename) —
never as the primary interface.

## One canonical cover, not an artwork gallery

`Artwork.Role` models `cover`, `poster` and `backdrop`, and both the MPEG-4
and Matroska writers take an array — so multi-artwork was listed as a cheap
win. It is not being built.

The developer's requirement is **canonical tags and a canonical cover**: one
correct image per file, the one every player shows. Backdrops and poster sets
are a media-server concern, the same territory `Sidecar files are not our job`
rules out — a second image that no player displays is a file that has to be
kept in sync for no benefit.

The model keeps `Role` because the *readers* meet files that carry several
images and the lossless invariant says they round-trip. The inspector shows
and edits the `.cover`, which is the one that means anything.

Revisit only if a target player appears that reads a second embedded image
and the developer wants it.

## Out of scope, permanently

Cloud sync, streaming, library server, "where to watch" data
(Watchmode). OmniTag edits tags on local files.
