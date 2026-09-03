# Status

Last updated: 2026-09-02. Update this file in the same commit as any change it
describes — a stale STATUS is worse than none, because the next session trusts it.

## Works today

| Area | State |
|---|---|
| Domain model | `MediaCore`: `MediaItem`, `TagSet`, `TagKey`, `Chapter`, `Artwork`. Foundation only. |
| Scanning | `LibraryScanner`: recursive walk, extension-typed, smart kind classifier (.m4b → audiobook, epub/pdf → book, SxxExx → TV), hidden files skipped. |
| Reading | `MediaTagReader` routes by container: AVFoundation for MPEG-4/mp3/wav/aiff, `MatroskaReader` for mkv, `EPUBReader` for epub, `PDFReader` for pdf. |
| Writing | `MediaTagWriter` routes: `MPEG4TagWriter` (MP4 family), `ID3TagWriter` (mp3), `MatroskaTagWriter` (mkv), `EPUBTagWriter` (epub), `PDFTagWriter` (pdf). |
| ID3 | Read **and** write. Writes v2.4/UTF-8, preserves unmanaged frames, `3/12` split. |
| MPEG-4 | Read **and** write. Standard atoms (`©nam`, `tvsh`, `trkn`…) plus freeform `----` for SERIES/ASIN/STUDIO. |
| Matroska | Read **and** write. Tags written by in-place patch — the file is never copied. |
| Chapters | Read for m4b/mp4 (chapter groups) and mkv (ChapterAtom). Editable in-place in Inspector and in Metadata Wizard. |
| Playback | Audio preview via `AVPlayer` (m4b, m4a, mp3, wav, aiff, flac) with scrubber and playhead chapter insertion. |
| Artwork | Original image resolution preserved by default; local artwork auto-discovery (`cover.jpg`) and clipboard paste (`⌘V`). |
| Writing safety | Stage to sibling temp → re-read to verify → atomic `replaceItemAt`. Previous tags archived as JSON. |
| Editing | `EditEngine`: batch `set`/`clear`/`replace`/`setKind`/`applyChapters` over a selection, undo/redo per batch, save only dirty files. `applySnapshot` writes the wizard's result as a **delta**. |
| UI | Three panes: kind sidebar with drop-reassignment; sortable, column-customisable table with covers and unsaved marks; batch inspector with in-place chapter studio and audio transport bar. |
| Books | EPUB read **and** write via a hand-rolled `ZipArchive`; OPF edited surgically, other entries copied compressed. PDF read and write via PDFKit. See `BOOKS.md`. |
| Metadata providers | `MetadataProvider` protocol. Audible + Audnexus for audiobooks, OpenLibrary for books. The wizard is provider-driven and serves both tabs. |
| Filenames | `FilenamePattern` renders tags into a name and parses a name back into tags. Rename sheet with live preview, presets, collision and missing-field refusals; renames are undoable. See `FILENAMES.md`. |
| Tests | 242, no network. Real media under `OMNITAG_REAL_MEDIA`, live APIs under `OMNITAG_LIVE`. |

## Does not work yet

- **flac, ogg/opus.** Scanned and listed, not parsed at all.
- **MOBI/AZW3 and CBZ.** Out of scope for now; considered and deferred.
- **An EPUB table of contents is read-only**, and an EPUB cover can be replaced
  but not added.
- **PDF artwork.** Page one is rendered as a preview; a PDF cannot store a cover.
  Encrypted and digitally-signed PDFs are refused on write.
- **mkv chapters and attachments are read-only.** Only the `Tags` element is
  written; editing chapters means the same patch machinery applied to `Chapters`.
- **Metadata providers.** Audiobooks (Audible + Audnexus) and books
  (OpenLibrary) done. TMDB, TVmaze, iTunes and MusicBrainz not started — the
  wizard button is disabled on tabs no provider serves.
- **Artwork beyond one cover.** One `.cover` image per file: drop, choose,
  find in folder, paste, remove. Backdrops and multiple roles are
  modelled but not editable.
- **Filename patterns name a file, not a path.** `%artist%/%album%/%title%`
  will not move a file into folders; `/` is sanitised to `-`. Batch rename
  cannot create directories.
- **Library persistence.** Nothing is remembered between launches; you re-add the folder each time.

`MediaTagReader.canRead` / `canWrite` is the machine-readable version of this
table, and the inspector warns on selections it cannot save. Keep all three in
step.

## Known rough edges

- `ZipArchive` reads a whole archive into memory (`ponytail:` marked). Fine at
  book sizes; a 300 MB illustrated EPUB would want a `FileHandle`.

- `visible` filters and sorts on every read and the table reads it several times
  per redraw (`ponytail:` marked in `App.swift`). Fine for hundreds.
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

## Verify the claims above

```sh
make test                                   # 242 tests
OMNITAG_REAL_MEDIA=~/Desktop/tp make test   # plus real-file assertions
OMNITAG_LIVE=1 make test                    # plus live Audible/Audnexus checks
make xctest                                 # same suite through the Xcode scheme
```
