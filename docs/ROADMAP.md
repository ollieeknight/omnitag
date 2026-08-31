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

## 1. mkv writing — in-place element rewrite

**The hard constraint:** these files are gigabytes. A remux to change a title is
unacceptable. Matroska anticipates this: `Void` elements are padding that can be
grown and shrunk.

**Approach:**

- Locate the existing `Tags` element (and `Chapters` if editing those). If the
  new serialised element fits in the old element plus any adjacent `Void`,
  overwrite in place and adjust the `Void` to absorb the difference.
- If it does not fit, append a new `Tags` element at the end of the Segment,
  turn the old one into `Void`, and update `SeekHead` if present. This is what
  `mkvpropedit` does.
- The Segment's declared size may need updating when appending. If the size is
  "unknown" (all-ones VINT), nothing to do.
- Never touch Clusters. Never rewrite the whole file.
- The write must still stage and verify: copy nothing, but re-parse the modified
  file before considering the write successful, and keep the tag backup.

**Tests first:** synthetic mkv fixtures from `EBMLBuilder` (already in the test
suite) covering: fits-in-place, needs-append, no-existing-Tags-element, and a
Void-adjacent case. Then the real-file test on a **copy** of Fire Walk with Me.

---

## 2. Artwork editing

Read exists (`Artwork` on `MediaItem`). Needed: add, replace, remove, and a
drag-and-drop well in the inspector. MPEG-4 uses the `covr` atom; mkv uses an
`AttachedFile` named `cover.jpg`; ID3 uses `APIC`. Resize on import — a 4000 px
poster in every file is how libraries balloon.

---

## 3. Metadata providers

`MetadataProvider` protocol per `ARCHITECTURE.md`. Order matters:

1. **TMDB** (movies + TV) — the highest-value one, and the only provider that
   needs a key. The key goes in the Keychain via a preferences pane, never in
   the binary or the repo.
2. **Audnexus** (audiobooks, ASIN-keyed, no key needed). The developer's m4b
   already carries its ASIN in a `CDEK` atom — use it as the lookup key.
3. **iTunes Search** (music, no key), MusicBrainz as fallback (1 req/s, real
   User-Agent required).
4. TVmaze if TMDB's episode data proves thin. Watchmode: out of scope, decided.

All clients behind `URLProtocol` stubs. No test may hit the network. Offline
must stay fully functional — providers enrich, nothing depends on them.

---

## 4. Chapter editing

Editing titles and times for m4b/mp4 (chapter track rewrite via `AVAssetWriter`)
and mkv (element rewrite, see #1). Depends on #1 landing first for the mkv half.

---

## 5. Filename ↔ tag conversion

Two directions, both Mp3tag staples:

- **Tag → filename**: a pattern like `%artist% - %title%` with a live preview
  and a dry run. Renames go through the same undo stack as tag edits.
- **Filename → tag**: parse `S01E01 - Northwest Passage` style names into
  season/episode/title. Preview before applying; never guess silently.

---

## 6. flac and ogg/opus

Vorbis comments — a simple `KEY=value` list, roughly 60 lines to read and write.
flac also has a `PICTURE` block for artwork. Lowest priority: no such files in
the developer's library yet.

---

## Not planned

- Cloud sync, streaming, playback, a library server.
- Watchmode / "where to watch" — streaming data, out of scope for a local tagger.
- Sandboxing / App Store distribution, unless the app is ever shipped to others.
