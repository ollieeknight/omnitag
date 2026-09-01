# Roadmap

Ordered. Each entry carries enough detail to start cold. Take the top unfinished
one unless told otherwise, and read `STATUS.md` first to confirm it is still the
top one.

---

## ✅ Done: mp3 writing (ID3v2.4)

`ID3v2.swift` (synchsafe integers, frame parse/serialise, merge) and
`ID3TagWriter.swift`. Writes v2.4/UTF-8, preserves every frame it does not
manage, drops superseded v2.3 frames (`TYER` → `TDRC`), packs `TRCK` as
`index/total`, and puts `TagKey.custom` values in `TXXX` frames. Refuses v2.2 and
unsynchronised tags rather than losing frames. Verified independently with
`ffprobe` on a copy of the real Badalamenti mp3: tags read back, custom frame
intact, duration unchanged.

---

## ✅ Done: mkv writing (in-place element patch)

`EBMLWriter` (VINT/element/Void serialisation) and `MatroskaTagWriter`. Three
cases, all seek-and-write: the new `Tags` element fits the old region plus any
adjacent `Void` (overwrite, pad the slack); it is the last element (overwrite,
change the file length); it fits nowhere (append at the end, blank the old one to
`Void`, repair the `SeekHead` entry). Segment size is rewritten in place. The
file is never copied: 8 ms on the 1.3 GB episode, 32 ms on the 6.5 GB film,
verified with `ffprobe` — durations unchanged, chapters intact, tags readable.

## ✅ Done: artwork editing

`CoverImage` resamples anything over 1400 px to JPEG on the way in and passes
smaller images through untouched. The inspector has a drop well with choose and
remove; the wizard's downloaded covers go through the same path. Still open:
roles beyond `.cover` (backdrops), and mkv `AttachedFile` artwork. MPEG-4 uses the `covr` atom; mkv uses an
`AttachedFile` named `cover.jpg`; ID3 uses `APIC`. Resize on import — a 4000 px
poster in every file is how libraries balloon.

---

## ✅ Done: the audiobook wizard — see `AUDIOBOOKS.md`

`MetadataAPI`, the tag diff (delta writes, tick-presets, per-row edit and
revert), artwork download to `covr`/`APIC`, the chapter diff with live strategy
preview, drag-and-drop import, and MPEG-4 chapter writing via
`MPEG4ChapterWriter`.

Left over: mkv chapters — see below.

## ✅ Done: book formats (EPUB + PDF)

`ZipArchive`, `OPFDocument`, `EPUBKeyMap`, `EPUBReader`, `EPUBTagWriter`,
`PDFReader`, `PDFTagWriter`, a Books tab, and `MetadataProvider` with
OpenLibrary behind it. See `BOOKS.md`. Left open: MOBI/AZW3, CBZ, adding a
cover to an EPUB that has none, and editing an EPUB's table of contents.

## 2. Metadata providers

`MetadataProvider` protocol per `ARCHITECTURE.md`. Order matters:

1. **TMDB** (movies + TV) — the highest-value one, and the only provider that
   needs a key. The key goes in the Keychain via a preferences pane, never in
   the binary or the repo.
2. ✅ **Audnexus** (audiobooks) and **OpenLibrary** (books) — both done and
   behind `MetadataProvider`.
3. **iTunes Search** (music, no key), MusicBrainz as fallback (1 req/s, real
   User-Agent required).
4. TVmaze if TMDB's episode data proves thin. Watchmode: out of scope, decided.

All clients behind `URLProtocol` stubs. No test may hit the network. Offline
must stay fully functional — providers enrich, nothing depends on them.

---

## 3. Chapter editing

✅ **MPEG-4 chapter writing** is done via `MPEG4ChapterWriter` (remuxing with `AVAssetWriter`).

**Remaining**: Editing titles and times for mkv (`Chapters` element, using the same patch machinery `MatroskaTagWriter`
already has — this half is now mostly plumbing).

---

## 4. Filename ↔ tag conversion

Two directions, both Mp3tag staples:

- **Tag → filename**: a pattern like `%artist% - %title%` with a live preview
  and a dry run. Renames go through the same undo stack as tag edits.
- **Filename → tag**: parse `S01E01 - Northwest Passage` style names into
  season/episode/title. Preview before applying; never guess silently.

---

## 5. flac and ogg/opus

Vorbis comments — a simple `KEY=value` list, roughly 60 lines to read and write.
flac also has a `PICTURE` block for artwork. Lowest priority: no such files in
the developer's library yet.

---

## Not planned

- Cloud sync, streaming, playback, a library server.
- Watchmode / "where to watch" — streaming data, out of scope for a local tagger.
- Sandboxing / App Store distribution, unless the app is ever shipped to others.
