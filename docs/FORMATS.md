# Formats

Where every `TagKey` physically lives, per container. This is the map you need
before touching a reader or writer — and the reason a key must never be added to
one side of a table only.

## Support matrix

| Container | Read | Write | Backend |
|---|---|---|---|
| m4a, m4b, mp4, m4v, mov | ✅ tags, chapters, artwork | ✅ tags, chapters | AVFoundation |
| mp3 | ✅ ID3v2 tags | ✅ writes v2.4 | AVFoundation read, `ID3TagWriter` write |
| wav, aiff | ✅ basic | ❌ | AVFoundation |
| mkv | ✅ tags, chapters, cover attachments | ✅ tags (in-place patch) | `MatroskaReader` / `MatroskaTagWriter` |
| flac, ogg, opus | ❌ listed only | ❌ | — |

`MediaTagReader.canRead` / `canWrite` encodes this; keep them in step.

## MPEG-4 (`MPEG4KeyMap`)

Atoms are written as `itsk/<code>` identifiers. Two traps, both learned the hard
way and both regression-tested:

1. **`©` comes back percent-escaped** as `%A9` when reading, and `%A9` is *not*
   valid UTF-8 percent encoding, so it cannot be decoded — both spellings are in
   the lookup table.
2. **Atom codes are exactly four characters.** `iTunEXTC` is not an atom, it is a
   freeform name; passing it as an atom throws
   `NSInvalidArgumentException: Bad identifier`.

| Key | Atom | Notes |
|---|---|---|
| title | `©nam` | |
| artist | `©ART` | |
| albumArtist | `aART` | |
| album | `©alb` | |
| genre | `©gen` | |
| comment | `©cmt` | |
| composer | `©wrt` | |
| grouping | `©grp` | |
| year | `©day` | may hold a full date (`2017-05-02`) |
| publisher | `©pub` | |
| narrator | `©nrt` | what Audiobookshelf reads |
| author | `©aut` | |
| director | `©dir` | |
| synopsis | `ldes` | long description |
| compilation | `cpil` | |
| showName | `tvsh` | |
| seasonNumber | `tvsn` | |
| episodeNumber | `tves` | |
| episodeTitle | `tven` | |
| trackNumber + trackTotal | `trkn` | one packed 8-byte atom, big-endian at offsets 2–5 |
| discNumber + discTotal | `disk` | same, 6 bytes |

Freeform (`itlk/com.apple.iTunes.<NAME>`), using names other tools already read:
`SERIES`, `SERIES-PART`, `ISBN`, `ASIN`, `STUDIO`, `iTunEXTC` (content rating).
Anything unrecognised round-trips as `TagKey.custom(name)`.

`iTunSMPB` is Apple's gapless-playback state, not a user tag — deliberately
filtered out on read.

## ID3v2 (`ID3KeyMap`)

AVFoundation surfaces frames as `id3/TIT2` on read; `ID3TagWriter` writes v2.4
by hand. Two encodings share the format and confuse parsers: the **tag** size is
always synchsafe (7 bits per byte), but **frame** sizes are synchsafe only in
v2.4 — in v2.3 they are plain big-endian. Below 128 the two agree, which is why a
short test fixture proves nothing.

| Key | Frame |
|---|---|
| title | `TIT2` |
| artist | `TPE1` |
| albumArtist | `TPE2` |
| album | `TALB` |
| genre | `TCON` |
| composer | `TCOM` |
| grouping | `TIT1` |
| publisher | `TPUB` |
| year | `TYER` (v2.3) / `TDRC` (v2.4) |
| comment | `COMM` |
| compilation | `TCMP` |
| trackNumber + trackTotal | `TRCK`, the `3/12` convention — split on read |
| discNumber + discTotal | `TPOS`, same |

Year frames may carry a full timestamp; the reader keeps the leading four digits.

On write: always v2.4, always UTF-8 (encoding byte `0x03`), 1 KB of padding, and
`TYER`/`TDAT`/`TIME`/`TRDA` dropped in favour of `TDRC` so a file never carries
two answers. Frames OmniTag does not manage are copied across byte-for-byte;
`TagKey.custom` values become `TXXX` (`description\0value`). v2.2 tags
(three-character ids) and unsynchronised tags are refused, not rewritten.

## Matroska (`MatroskaKeyMap`)

Tag names are strings, and **their meaning depends on the target level**. This is
the thing most taggers get wrong:

| Level | Means | `TITLE` maps to | `PART_NUMBER` maps to |
|---|---|---|---|
| 70 | COLLECTION / series | `showName` | `seriesIndex` |
| 60 | SEASON / volume | `album` | `seasonNumber` |
| 50 (default) | EPISODE / movie | `title` | `episodeNumber` |

Level-independent names: `ARTIST`, `ALBUM`, `ALBUM_ARTIST`, `COMPOSER`, `GENRE`,
`COMMENT`, `DESCRIPTION`/`SUMMARY`/`SYNOPSIS` → synopsis, `DIRECTOR`,
`PRODUCTION_STUDIO`, `PUBLISHER`, `LAW_RATING` → contentRating, `DATE_RELEASED`
→ year, `SUBTITLE` → episodeTitle, `ISBN`, `NARRATOR`, `AUTHOR`, `TOTAL_PARTS`.
Unknown names round-trip as `custom("mkv/NAME")`.

**Tags targeting a TrackUID are ignored**: that is where mkvmerge writes `BPS`,
`NUMBER_OF_FRAMES`, `_STATISTICS_*` and friends. They describe the encoding, not
the work, and they polluted the tag set until filtered.

### Element ids the parser knows

```
1A45DFA3 EBML header      18538067 Segment        1549A966 Info
2AD7B1   TimestampScale   4489     Duration       7BA9     Title
1043A770 Chapters         45B9     EditionEntry   B6       ChapterAtom
91       ChapterTimeStart 80       ChapterDisplay 85       ChapString
1254C367 Tags             7373     Tag            63C0     Targets
68CA     TargetTypeValue  63C5     TagTrackUID    67C8     SimpleTag
45A3     TagName          4487     TagString      1941A469 Attachments
61A7     AttachedFile     4660     FileMimeType   465C     FileData
```

Void (`EC`) is padding, legal anywhere, and the mechanism that makes in-place
editing possible. `SeekHead` (`114D9B74`) holds `Seek` (`4DBB`) entries of
`SeekID` (`53AB`) + `SeekPosition` (`53AC`), which must be repaired when an
element moves — a stale pointer is worse than none.

Everything else — Clusters, Tracks, Cues — is skipped by size and never read. Chapter times are absolute **nanoseconds**, independent of
TimestampScale; the Duration in `Info` is in TimestampScale ticks.

### Writing mkv

Never remux. `MatroskaTagWriter` plans a set of byte patches and applies them
with `FileHandle`, so cost is independent of file size:

| Situation | What happens |
|---|---|
| New element ≤ old region + following `Void` | Overwrite in place, pad the slack with `Void` |
| Old element is last in the file | Overwrite, then grow or truncate the file |
| Neither | Append at the end, blank the old region to `Void`, repair `SeekHead` |

The Segment's own size VINT is rewritten in place; its width cannot change, so a
file whose size field is too narrow to describe the new length is refused rather
than corrupted. A one-byte gap cannot hold a `Void` (minimum two bytes), which is
why `EBMLWriter.size` can force a wider-than-minimal encoding.

Ordering matters for crash safety: the new element is appended **before** the old
one is blanked, so an interrupted write leaves the original element intact and
the appended bytes outside the declared Segment, where they are ignored.

## Adding a format

1. Fixture in `Tests/TagIOTests/TwinPeaks.swift` (or an `EBMLBuilder`-style
   synthetic builder for binary containers).
2. Failing tests: read, write, round-trip, failed-write-leaves-original.
3. Reader/writer in `Sources/TagIO/`, plus a bidirectional key map.
4. A case in `MediaTagReader` and in `canRead`/`canWrite`.
5. Update the matrix above and `STATUS.md`.

If step 4 needs changes anywhere else, the abstraction is wrong — say so rather
than working around it.
