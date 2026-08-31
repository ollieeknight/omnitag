# Status

Last updated: 2026-08-31. Update this file in the same commit as any change it
describes — a stale STATUS is worse than none, because the next session trusts it.

## Works today

| Area | State |
|---|---|
| Domain model | `MediaCore`: `MediaItem`, `TagSet`, `TagKey`, `Chapter`, `Artwork`. Foundation only. |
| Scanning | `LibraryScanner`: recursive walk, extension-typed, hidden files and packages skipped. |
| Reading | `MediaTagReader` routes by container: AVFoundation for MPEG-4/mp3/wav/aiff, `MatroskaReader` for mkv. |
| Writing | `MediaTagWriter` routes: `MPEG4TagWriter` (MP4 family), `ID3TagWriter` (mp3), `MatroskaTagWriter` (mkv). |
| ID3 | Read **and** write. Writes v2.4/UTF-8, preserves unmanaged frames, `3/12` split. |
| MPEG-4 | Read **and** write. Standard atoms (`©nam`, `tvsh`, `trkn`…) plus freeform `----` for SERIES/ASIN/STUDIO. |
| Matroska | Read **and** write. Tags written by in-place patch — the file is never copied. |
| Chapters | Read for m4b/mp4 (chapter groups) and mkv (ChapterAtom). Not editable yet. |
| Writing safety | Stage to sibling temp → re-read to verify → atomic `replaceItemAt`. Previous tags archived as JSON. |
| Editing | `EditEngine`: batch `set`/`clear`/`replace` over a selection, undo/redo per batch, save only dirty files. |
| UI | Three panes: kind sidebar, sortable table, batch inspector with per-kind field sets and chapter list. |
| Audiobook metadata | `MetadataAPI`: Audible search + Audnexus detail/chapters, region fallback, ASIN/URL input. See `AUDIOBOOKS.md`. |
| Tests | 108, no network. Real media under `OMNITAG_REAL_MEDIA`, live APIs under `OMNITAG_LIVE`. |

## Does not work yet

- **flac, ogg/opus.** Scanned and listed, not parsed at all.
- **mkv chapters and attachments are read-only.** Only the `Tags` element is
  written; editing chapters means the same patch machinery applied to `Chapters`.
- **Chapter editing.** Read-only everywhere.
- **Artwork editing.** Read only; no add/replace/remove.
- **Metadata providers.** Audiobooks done (Audible + Audnexus). TMDB, TVmaze,
  iTunes and MusicBrainz not started.
- **The audiobook wizard UI.** The API layer is done; the drag-and-drop,
  search sheet, tag diff and chapter diff are not built yet.
- **Filename ↔ tag conversion.** Not started.
- **Library persistence.** Nothing is remembered between launches; you re-add the folder each time.

`MediaTagReader.canRead` / `canWrite` is the machine-readable version of this
table, and the inspector warns on selections it cannot save. Keep all three in
step.

## Known rough edges

- Tag reading is serial, one file at a time (`ponytail:` marked in `App.swift`).
  Fine for hundreds of files, visible at thousands.
- `MediaItem.id` is the URL, so a file moved outside the app loses its identity
  (`ponytail:` marked in `MediaItem.swift`).
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
make test                                   # 108 tests
OMNITAG_REAL_MEDIA=~/Desktop/tp make test   # plus real-file assertions
OMNITAG_LIVE=1 make test                    # plus live Audible/Audnexus checks
make xctest                                 # same suite through the Xcode scheme
```
