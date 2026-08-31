# Status

Last updated: 2026-08-31. Update this file in the same commit as any change it
describes — a stale STATUS is worse than none, because the next session trusts it.

## Works today

| Area | State |
|---|---|
| Domain model | `MediaCore`: `MediaItem`, `TagSet`, `TagKey`, `Chapter`, `Artwork`. Foundation only. |
| Scanning | `LibraryScanner`: recursive walk, extension-typed, hidden files and packages skipped. |
| Reading | `MediaTagReader` routes by container: AVFoundation for MPEG-4/mp3/wav/aiff, `MatroskaReader` for mkv. |
| ID3 | Read only. Frames mapped to real keys, `3/12` track convention split. |
| MPEG-4 | Read **and** write. Standard atoms (`©nam`, `tvsh`, `trkn`…) plus freeform `----` for SERIES/ASIN/STUDIO. |
| Matroska | Read only. Info, Tags (target-level aware), Chapters, cover attachments. |
| Chapters | Read for m4b/mp4 (chapter groups) and mkv (ChapterAtom). Not editable yet. |
| Writing safety | Stage to sibling temp → re-read to verify → atomic `replaceItemAt`. Previous tags archived as JSON. |
| Editing | `EditEngine`: batch `set`/`clear`/`replace` over a selection, undo/redo per batch, save only dirty files. |
| UI | Three panes: kind sidebar, sortable table, batch inspector with per-kind field sets and chapter list. |
| Tests | 48, no network. Real-media assertions when `OMNITAG_REAL_MEDIA` is set. |

## Does not work yet

- **mp3 writing.** Reads fine, cannot save. Next task — see ROADMAP.
- **mkv writing.** Same. Must be an in-place element rewrite, never a remux.
- **flac, ogg/opus.** Scanned and listed, not parsed at all.
- **Chapter editing.** Read-only everywhere.
- **Artwork editing.** Read only; no add/replace/remove.
- **Metadata providers.** No network code exists at all yet.
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

## Verify the claims above

```sh
make test                                   # 48 tests
OMNITAG_REAL_MEDIA=~/Desktop/tp make test   # plus real-file assertions
make xctest                                 # same suite through the Xcode scheme
```
