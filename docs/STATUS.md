# Status

Last updated: 2026-09-04 (three of the four remaining v1 items: custom tags
are now visible and editable, the chapter-boundary check is reachable from the
inspector, and the wizard's movie-vs-TV choice writes back to the file's kind.
`ROADMAP.md` defines what v1 means and what is left — one item, 2h).

## Works today

| Area | State |
|---|---|
| Domain model | `MediaCore`: `MediaItem`, `TagSet`, `TagKey`, `Chapter`, `Artwork`, `SubtitleTrack`. Foundation only. |
| Scanning | `LibraryScanner`: recursive walk, extension-typed. The movie/TV/audiobook/book classifier is `LibraryModel.detectKind` in `App.swift` (not the scanner itself) — SxxExx pattern → TV, everything else video → movie, `.m4b` → audiobook, epub/pdf → book. Never trusts which sidebar tab is active for the movie-vs-TV decision, so a mixed folder scanned from any tab still lands correctly. Hidden files skipped. |
| Reading | `MediaTagReader` routes by container: AVFoundation for MPEG-4/mp3/wav/aiff, `MatroskaReader` for mkv, `EPUBReader` for epub, `PDFReader` for pdf. |
| Writing | `MediaTagWriter` routes: `MPEG4TagWriter` (MP4 family), `ID3TagWriter` (mp3), `MatroskaTagWriter` (mkv), `EPUBTagWriter` (epub), `PDFTagWriter` (pdf). |
| ID3 | Read **and** write. Writes v2.4/UTF-8, preserves unmanaged frames, `3/12` split. |
| MPEG-4 | Read **and** write. Standard atoms (`©nam`, `tvsh`, `trkn`…), freeform `----` (mean-agnostic, case-insensitive, Libation/Tone/Mp3tag compat), `itsk/asin`, and narrator/author read fallbacks. |
| Matroska | Read **and** write. Tags, cover artwork (`AttachedFile`) and chapters written by in-place patch — the file is never copied. Subtitle track metadata (language, name, default/forced/enabled) also editable: `Tracks` is byte-surgically patched rather than regenerated, so video/audio tracks and unmanaged fields (`CodecPrivate`) round-trip untouched. No add/remove of tracks — that means remuxing every Cluster, out of scope. |
| Chapters | Read and written for the MP4 family (`MPEG4ChapterWriter`) and mkv (`MatroskaTagWriter`, same in-place patch as its tags and artwork). Edited in the inspector's chapter list (mp3/epub/pdf show the list read-only, per `MediaTagReader.canWriteChapters`) and reconciled with a provider in the wizard. Titles that a provider cannot reproduce are protected: **any** non-generic title makes the wizard start with chapters skipped, and the notice names the titles at risk. A count mismatch pairs by timestamp, not index, and reports how many actually matched. `ChapterBoundaryCheck` measures whether a mark lands in the pause where a chapter really breaks — against a real 50-book library it found 16 books whose marks sat 2–7 seconds early. See `AUDIOBOOKS.md`. |
| Subtitle tracks | mkv only (`MediaTagReader.canWriteSubtitleTracks`). A small inspector section lists each track (codec, language, name, default/forced/enabled) for a single-file selection, editable and undoable through `EditEngine.applySubtitleTracks`. No provider fetches subtitle data — chapter markers and subtitle tracks are both DVD/Blu-ray authoring artifacts, never published metadata, so this is purely local editing of what a rip already has. |
| Playback | Audio preview via `AVPlayer` (m4b, m4a, mp3, wav, aiff, flac) with scrubber and playhead chapter insertion. |
| Artwork | Original image resolution preserved by default; local artwork auto-discovery (`cover.jpg`) and clipboard paste (`⌘V`). mkv writes it as an `AttachedFile`, alongside mp4's `covr` and mp3's `APIC`. |
| Writing safety | Stage to sibling temp → re-read to verify → atomic `replaceItemAt`. Previous tags archived as JSON. |
| Editing | `EditEngine`: batch `set`/`clear`/`replace`/`setKind`/`applyChapters`/`applySubtitleTracks` over a selection, undo/redo per batch, save only dirty files. `applySnapshot` writes the wizard's result as a **delta**. |
| UI | Three panes. **Sidebar**: `All` above a "Library" section of the five kinds, each with its own tint and a count badge, drop-reassignment onto any kind row, and a save button when there are unsaved changes. **Table**: sortable and column-customisable, with per-scope default columns (`All` shows Kind and a universal "By"; each kind shows its own vocabulary), covers, and an unsaved dot. `LibraryScope` — not a sixth `MediaKind` — is what the sidebar selects; `LibraryModel.kind` is derived from it plus the selection. **Inspector**: batch editor with a Kind picker that reads "Multiple" rather than misreporting a mixed selection, `kindGuessReason` for a guessed video kind, editable chapter and subtitle-track lists, and an audio transport bar. Counts and save progress live in the window subtitle; only save failures get a bar of their own. `LibraryModel.visible` is cached against every input it depends on; cover thumbnails are decoded once per distinct image via `ThumbnailCache`. |
| Library persistence | The folders you added are remembered (`LibraryRootStore`, plain file URLs in `UserDefaults` — not security-scoped bookmarks, because the app is not sandboxed) and re-scanned on launch. Only the *roots* are stored, never the scanned items: files move and get retagged by other tools while the app is closed, so a serialised item list would be a cache that is wrong more often than useful. Removing the last file also forgets the roots, or the next launch would bring back everything just removed. A restored library lands on a tab that actually has files in it rather than the empty Music tab it starts on. |
| Books | EPUB read **and** write via a hand-rolled `ZipArchive`; OPF edited surgically, other entries copied compressed. PDF read and write via PDFKit. See `BOOKS.md`. |
| Metadata providers | `MetadataProvider` protocol, and every kind now has one. Audible + Audnexus (audiobooks), OpenLibrary (books), TMDB (movies + TV; key via Keychain/Preferences, `⌘,` — a provider that needs a key it lacks says so on arrival, with a link to Preferences, rather than after a doomed search), and iTunes Search (music, no key, no detail round trip because `/lookup` returns nothing `/search` does not). The wizard is provider-driven; a TV search result is a show, so it adds an episode-picker step, opened on the season the filename names with the matching episode marked. A scene-release filename is cleaned of resolution/codec/release-group noise before searching, and its year breaks TMDB's popularity ties. For music, a multi-file selection is written album fields only — one song's title and track number can never be right for a whole album. See `MOVIES_TV.md` and `MUSIC.md`. |
| Inspection | Two surfaces for checking what a file really holds. **Other tags**: the atoms and frames OmniTag does not model, listed and editable in the inspector — the lossless invariant promises they survive, and this is how the user confirms it. **Chapter marks**: `ChapterBoundaryCheck` measures whether each mark sits where the audio breaks, reporting a shape ("In a pause, 2.0s after the previous audio ended") rather than a verdict, with a one-click nudge to the real break. See `AUDIOBOOKS.md`. |
| Wizard test coverage | `OmniTagAppTests` (new): `MetadataWizardModel.buildSnapshot()`, the mkv-artwork skip, the multi-file chapter/episode guards, and TV show-vs-episode routing, all driven against a fake `MetadataProvider` — no network, no view rendering. |
| Filenames | `FilenamePattern` renders tags into a name and parses a name back into tags. Rename sheet with live preview, presets, collision and missing-field refusals; renames are undoable. See `FILENAMES.md`. |
| Tests | 459, no network. Real media under `OMNITAG_REAL_MEDIA` (now includes subtitle-track assertions against the developer's real mkv files, both single-SRT and mixed SRT/PGS), live APIs under `OMNITAG_LIVE`. |
| Tooling | `make check` (lint + audit + test) passes end to end. `make audit` uses `periphery-cli`, the free-tier successor to the archived open-source `periphery` — see `docs/DEVELOPMENT.md`. |

## Does not work yet


- **flac, ogg/opus, avi.** Scanned and listed, not parsed at all —
  `MediaTagReader.canRead` is false for all four, so the inspector shows its
  "no writer yet — edits cannot be saved" warning rather than failing on save.
  avi is the one of these that lands on a *video* tab, so it is the one a
  movie library is most likely to meet; it is unlikely to grow a writer
  (RIFF `INFO` chunks are a dead end that nothing reads).
- **MOBI/AZW3 and CBZ.** Out of scope for now; considered and deferred.
- **An EPUB table of contents is read-only**, and an EPUB cover can be replaced
  but not added.
- **PDF artwork.** Page one is rendered as a preview; a PDF cannot store a cover.
  Encrypted and digitally-signed PDFs are refused on write.
- **Metadata providers.** Audiobooks (Audible + Audnexus), books
  (OpenLibrary), and movies/TV (TMDB) done — see `docs/MOVIES_TV.md`.
  TVmaze and MusicBrainz not started. Every kind now has a provider, so the
  wizard button is no longer disabled on any tab.
- **No regex in Find & Replace.** Plain substring only. `TagEdit.replace`
  and the text transforms (case, whitespace, copy, swap) ship in the Edit
  Tags sheet (⌘⇧E); a regex option is `ROADMAP.md` 2a's follow-on.
- **No saved actions or recipes.** Every edit is typed fresh; nothing can be
  saved and re-run. This is the category's centre of gravity — see
  `COMPETITION.md`. `ROADMAP.md` 2d.
- **Search is a flat substring match** over eight hardcoded fields, plus one
  "unsaved only" toggle. No field-scoped queries, no saved filters, and no
  audit views ("missing artwork", "no year") — which is the form that
  actually matters, since tagging is exception-driven. `ROADMAP.md` 2c.
- **No duplicate detection.** Nothing finds the same track twice.
  `ROADMAP.md` 2g.
- **No CSV import or export**, so no spreadsheet round-trip and no cheap
  whole-library tag backup. `ROADMAP.md` 2f.
- **One cover per file, by design.** Drop, choose, find in folder, paste,
  remove. `Artwork.Role` models poster and backdrop so files carrying them
  round-trip losslessly, but only the `.cover` is editable — see
  `DECISIONS.md`, "One canonical cover, not an artwork gallery".
- **The wizard writes one result to the whole selection.** Correct for one
  file; for an album or a season folder each file needs its *own* match. The
  music per-track guard (`MUSIC.md`) and the single-episode picker
  (`MOVIES_TV.md`) are both working around this. `ROADMAP.md` 2h.
- **A custom tag over 120 characters is shown but not editable.** The
  developer's Audible files carry a multi-kilobyte base64 blob; it
  round-trips whole and is listed with its length, but a 5 000-character
  text field is a way to destroy it by accident rather than edit it.
- **Filename patterns name a file, not a path.** `%artist%/%album%/%title%`
  will not move a file into folders; `/` is sanitised to `-`. Batch rename
  cannot create directories.


`MediaTagReader.canRead` / `canWrite` is the machine-readable version of this
table, and the inspector warns on selections it cannot save. Keep all three in
step.

## Known rough edges

- `ZipArchive` reads a whole archive into memory (`ponytail:` marked). Fine at
  book sizes; a 300 MB illustrated EPUB would want a `FileHandle`.

- Removing files from the library purges their undo history — it is the one
  action in the app that cannot be undone, so it asks first when edits are
  pending.

- Tag reading is serial, one file at a time (`ponytail:` marked in `App.swift`).
  Fine for hundreds of files, visible at thousands.
- `MediaItem.id` is the URL, so a file moved *outside* the app loses its
  identity (`ponytail:` marked in `MediaItem.swift`). A rename made *inside* the
  app is fine: `EditEngine.rename` re-keys the working set, the baseline and
  both history stacks.
- Audible m4b files carry a multi-kilobyte base64 `JSON` atom. It round-trips
  correctly but is ugly if ever surfaced raw in the UI.
- `.m4b` is written as `AVFileType.m4a`; AVFoundation has no separate m4b type.
  The extension is preserved, which is what players key on.
- ID3v2.2 and unsynchronised tags are **refused** on write rather than rewritten,
  because we cannot re-encode their frames faithfully. No such file has turned up
  yet; if one does, the error names the reason.
- An existing ID3v1 128-byte trailer is left alone by the mp3 writer, so it can
  go stale. Harmless — every modern player prefers v2 — but worth stripping when
  someone complains.
- The mkv writer patches the file in place rather than staging a copy, because
  staging a 6 GB film to change a title is exactly the cost the design avoids.
  It therefore has no atomic swap: the mitigations are that every patch lands
  outside the Clusters, the previous tags are archived first, and the file is
  re-parsed immediately after writing.
- `MPEG4TagWriter` still rewrites through `AVAssetExportSession`, so tagging a
  large mp4 costs a full re-mux. Matching the mkv approach (patch the `moov`
  atom) is a worthwhile follow-up, not yet scheduled.
- **A passthrough export drops the chapter track**, verified against a real m4b,
  so any MPEG-4 file that has chapters is written by `MPEG4ChapterWriter`
  instead — even when only a title changed. It copies the audio without
  re-encoding: a 234 MB, 10.7-hour audiobook takes about 1.2 seconds.
- `MPEG4ChapterWriter` keeps the first audio track and nothing else, so a file
  with a second audio or video track loses it. No audiobook has one.
- The Nero `chpl` atom some taggers write alongside the chapter track is not
  reproduced. Every player that matters reads the chapter track.

## Verify the claims above

```sh
make test                                   # 459 tests
OMNITAG_REAL_MEDIA=~/Desktop/tp make test   # plus real-file assertions
OMNITAG_LIVE=1 make test                    # plus live Audible/Audnexus checks
make xctest                                 # same suite through the Xcode scheme
```
