# Roadmap

Ordered. Each entry carries enough detail to start cold. Take the top unfinished
one unless told otherwise, and read `STATUS.md` first to confirm it is still the
top one.

---

## 1. mp3 writing — hand-rolled ID3v2.4

**Why hand-rolled:** ID3TagEditor would work, but the spec is stable, we need
frame-level control to avoid dropping frames we do not model, and the project
holds a zero-dependency line. Decided; do not re-litigate without a new reason.

**Where:** new `Sources/TagIO/ID3TagWriter.swift`, registered in
`MediaTagReader.canWrite` and in `FileTagWriter`.

**Shape of the work:**

- An mp3 file is `[ID3v2 tag][audio frames][optional ID3v1 128-byte trailer]`.
  Writing means building a fresh tag block and splicing it in front of the audio
  — the audio bytes are never touched.
- Header: `"ID3"`, version `0x04 0x00`, flags `0x00`, then a **synchsafe** size
  (7 bits per byte). Getting synchsafe wrong is the classic ID3 bug; unit-test
  the encoder and decoder against known values before writing a single file.
- Frames: 4-char id, synchsafe size, 2 flag bytes, then the payload. Text frames
  start with an encoding byte — use `0x03` (UTF-8) and write the string plain.
- `TXXX` frames carry `description\0value` and are where `TagKey.custom` values
  that are not real frames should land, so the round-trip stays lossless.
- Preserve unknown frames: read the existing tag first, keep every frame we do
  not manage, and merge. Dropping a frame the user cared about is the failure
  mode this whole design exists to prevent.
- Padding: write ~1 KB of zero padding after the frames so a later edit that
  grows slightly can be done in place. (In-place rewriting is a later
  optimisation; the first version rewrites the file through the same staged
  temp + verify + atomic replace path as MPEG-4.)
- `ID3KeyMap` already has the read mapping. Extend it into a bidirectional table
  the way `MPEG4KeyMap` is, so reader and writer cannot drift.

**Tests to write first:**

- Synchsafe encode/decode round-trip, including the 0x7F/0x80 boundary.
- Frame header round-trip for a text frame and a `TXXX` frame.
- Full write → read of the Twin Peaks theme fixture: every key survives.
- An mp3 with an unknown frame keeps that frame after a write.
- A failed write leaves the original byte-identical (mirror the MPEG-4 test).
- Real-file test against `01 - Twin Peaks Theme.mp3`: **copy it into a temp
  directory first**, never write to the developer's library in a test.

**Fixture generation:** `afconvert` cannot produce mp3. Either build a minimal
valid mp3 in the test (a silent MPEG-1 Layer III frame header plus zeroed data
is enough for a tag round-trip, since we never decode the audio), or copy the
real file when `OMNITAG_REAL_MEDIA` is set. Prefer the synthetic one so the
suite is green without the developer's media.

---

## 2. mkv writing — in-place element rewrite

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

## 3. Artwork editing

Read exists (`Artwork` on `MediaItem`). Needed: add, replace, remove, and a
drag-and-drop well in the inspector. MPEG-4 uses the `covr` atom; mkv uses an
`AttachedFile` named `cover.jpg`; ID3 uses `APIC`. Resize on import — a 4000 px
poster in every file is how libraries balloon.

---

## 4. Metadata providers

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

## 5. Chapter editing

Editing titles and times for m4b/mp4 (chapter track rewrite via `AVAssetWriter`)
and mkv (element rewrite, see #2). Depends on #2 landing first for the mkv half.

---

## 6. Filename ↔ tag conversion

Two directions, both Mp3tag staples:

- **Tag → filename**: a pattern like `%artist% - %title%` with a live preview
  and a dry run. Renames go through the same undo stack as tag edits.
- **Filename → tag**: parse `S01E01 - Northwest Passage` style names into
  season/episode/title. Preview before applying; never guess silently.

---

## 7. flac and ogg/opus

Vorbis comments — a simple `KEY=value` list, roughly 60 lines to read and write.
flac also has a `PICTURE` block for artwork. Lowest priority: no such files in
the developer's library yet.

---

## Not planned

- Cloud sync, streaming, playback, a library server.
- Watchmode / "where to watch" — streaming data, out of scope for a local tagger.
- Sandboxing / App Store distribution, unless the app is ever shipped to others.
