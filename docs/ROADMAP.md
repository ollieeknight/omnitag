# Roadmap

Ordered. Each entry carries enough detail to start cold. Take the top unfinished
one unless told otherwise, and read `STATUS.md` first to confirm it is still the
top one.

The ordering below item 1 comes from `COMPETITION.md`'s 2024–2026 survey of
what this category's users actually ask for. The short version: format
coverage and provider breadth are no longer where the value is — **throughput
is**. Item 2 is therefore ahead of new formats, and deliberately ahead of
more providers.

## What v1 means

**v1 is the release the developer trusts on their own library.** Not a public
launch — see "After v1" for that.

The sorting rule follows from it, and it is the only rule:

> **A thing that can silently lose or mis-write data is v1.
> A thing that only costs time is not.**

Time can be spent; a destroyed tag cannot be recovered. Everything below is
sorted by that test, not by how interesting it is to build.

### The v1 list

| | Item | Why it is v1 |
|---|---|---|
| ✅ | Chapter-title protection | Was silently overwriting irreplaceable titles in 9 of 50 real books |
| ✅ | Find & Replace + transforms | The engine could do it and nothing could reach it |
| ✅ | Column and sort persistence | Reset every launch, right after the library learned to persist |
| ✅ | Library persistence | Re-adding the folder every launch |
| ✅ | Every kind has a provider | Music had none at all |
| | **2h. Per-file batch fetch** | The wizard writes **one** result to a whole selection. Two guards work around it; both are correct and both cost real capability. This is the last place OmniTag can write the wrong thing to the right file. |
| ✅ | **2j. Custom-tag visibility** | Unknown atoms round-trip but cannot be seen or edited. The lossless invariant holds, but the user cannot verify it — and cannot fix a bad custom tag at all. |
| ✅ | **2k. Boundary check in the UI** | Built and tested, engine-only. It found real defects in 16 of 50 books; leaving it unreachable wastes the one thing that catches them. |
| ✅ | **2l. The wizard's kind write-back** | A file can leave the wizard tagged TV while the sidebar files it as a movie. Two places holding one fact, able to disagree. |

Everything on that list either loses data, hides data, or writes the wrong
data. Nothing on it is there because it would be nice.

**One item left: 2h.** Everything else on the v1 list has shipped.

### Explicitly *not* v1

Each of these costs time, never correctness:

- **2c. Audit views**, **2d. Saved actions**, **2f. CSV**, **2g. Duplicates**,
  **2i. Parallel scanning** — throughput, which is what a *public* release
  needs (`COMPETITION.md`) and what a personal one can live without.
- **flac / ogg / opus / avi** — unreadable, but honestly reported as such, and
  absent from the developer's library.
- **Regex in Find & Replace**, **filename patterns into subfolders**,
  **EPUB ToC editing**, **MOBI/CBZ**.
- **Serial tag reading** — slow at thousands of files, not wrong.

### After v1

A public release (Homebrew, strangers' libraries) needs the throughput block
above plus onboarding and error recovery for files unlike the developer's.
`COMPETITION.md` ranks that work; this file's item 2 is the plan for it.

---


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
remove; the wizard's downloaded covers go through the same path. MPEG-4 uses
the `covr` atom; mkv writes an `AttachedFile` named `cover.jpg`/`cover.png`,
patched in place by the same machinery as `Tags`; ID3 uses `APIC`. Resize on
import — a 4000 px poster in every file is how libraries balloon. Still open:
roles beyond `.cover` (backdrops).

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

## 1. Metadata providers

`MetadataProvider` protocol per `ARCHITECTURE.md`. Order matters:

1. ✅ **Done: TMDB** (movies + TV). `TagKey.tmdbID`, `TMDBKeyStore`
   (Keychain), `TMDBClient` (movie/TV search, movie/show/episode detail,
   season episode list), `TMDBProvider` behind `MetadataProvider`, a
   Preferences pane (`⌘,`) for the key, and the wizard's `.episode` step for
   picking a season/episode before a TV file's tag diff is built. Verified
   against the real API and the developer's own Twin Peaks files (movie +
   S01E01). See `docs/MOVIES_TV.md`.
2. ✅ **Audnexus** (audiobooks) and **OpenLibrary** (books) — both done and
   behind `MetadataProvider`.
3. ✅ **Done: iTunes Search** (music, no key). `ITunesClient`,
   `ITunesProvider`, music fields on `MetadataRecord` (`album`,
   `albumArtist`, track/disc numbers), and the wizard's album-safe guard so
   one song's title and number never land on a whole album. Verified against
   the live API and the developer's own Badalamenti mp3. See `docs/MUSIC.md`.
   **MusicBrainz** stays the unbuilt fallback (1 req/s, real User-Agent
   required) — worth building when iTunes coverage is shown to be thin, not
   before.
4. TVmaze if TMDB's episode data proves thin. Watchmode: out of scope, decided.

All clients behind `URLProtocol` stubs. No test may hit the network. Offline
must stay fully functional — providers enrich, nothing depends on them.

---

## ✅ Done: chapter editing

**MPEG-4** via `MPEG4ChapterWriter` (remuxing with `AVAssetWriter`). **mkv** via
`MatroskaTagWriter` (in-place patch of a `Chapters`/`EditionEntry`/`ChapterAtom`
element, same machinery as its `Tags` and `Attachments`). Both wired into the
inspector's chapter list; `MediaTagReader.canWriteChapters` gates the UI for
containers (mp3, epub, pdf) whose chapters are read-only.

## ✅ Done: mkv subtitle track metadata

Language, track name, and default/forced/enabled flags on subtitle tracks
already embedded in an mkv — mkv only (`MediaTagReader.canWriteSubtitleTracks`);
mp4's text tracks are a separate, rarer mechanism this writer does not touch.
`MatroskaTagWriter.patchTracks` byte-copies every TrackEntry it isn't editing
and every unmanaged field of one it is, so video/audio tracks and binary blobs
like `CodecPrivate` survive untouched. A small inspector section lists tracks
for a single-file selection; edits go through `EditEngine.applySubtitleTracks`,
undoable like everything else. No add/remove of tracks and no ASS/SSA style
header editing — both mean touching Cluster block data, a real remux this
writer's whole design avoids. See `MOVIES_TV.md`'s ninth pass.

---

## ✅ Done: filename ↔ tag conversion

`FilenamePattern` (`MediaCore`) tokenises `%field%` patterns and both renders
and parses them; `RenamePlan` (`EditEngine`) turns a selection plus a pattern
into a preview and the moves it implies; `EditEngine.rename` performs them and
re-keys everything a URL identifies, so unsaved edits follow the file and ⌘Z
moves it back. `applyTagDeltas` writes parsed names as one undoable batch.
`RenameSheet` is the UI: two directions, per-kind presets, a field menu, and a
row-by-row preview that refuses collisions and missing fields. See
`FILENAMES.md`.

Left open: patterns that write into subfolders, and a scripting layer
(`$num()`, `$upper()`) — neither has been asked for.

---

## ✅ Done: library persistence

The folders you added are remembered and re-scanned on launch —
`LibraryRootStore` (plain file URLs in `UserDefaults`; not security-scoped
bookmarks, because the app is not sandboxed). Only the roots are stored, never
the scanned items: a rescan is fast and is the only version that can be right,
since files move and get retagged by other tools while the app is closed.
Removing the last file forgets the roots too, or the next launch would restore
everything just removed. `LibraryModel.restore()` also switches to a tab that
has files in it, rather than leaving a restored film library staring at the
empty Music tab the app starts on.

---

## 2. Power-user throughput

The 2024–2026 competitive survey (`COMPETITION.md`) is unambiguous: this
category's value is *finishing a 5,000-file clean-up without losing work*,
and this block is where OmniTag is weakest. Ordered so each item is usable on
its own and each one feeds the next.

### ✅ 2a. Find & Replace across a selection — done

`TagEdit.replace(key:find:with:)` already exists in `EditEngine`, is tested,
and has **no UI** — it cannot be reached from anywhere in the app. Mp3tag's
most-used action. A sheet: field picker, find, replace, a live preview of the
affected rows, applied as one undoable batch like every other edit.

Add a regex option only once plain substring is shipped and someone asks.

### ✅ 2b. Bulk text transforms — done

The steps a recipe is built from, so they come before recipes: Title Case /
UPPER / lower, trim whitespace, swap two fields, copy one field to another,
auto-number tracks across a selection. Pure `MediaCore` string work plus the
same sheet 2a introduces; each becomes a `TagEdit` case so undo is free.

### 2c. Audit views and saved filters

Search today is a flat substring over eight hardcoded fields, plus one
"unsaved only" toggle. The valuable form is exception-finding: **missing
artwork**, **no year**, **missing track number**, **unsaved**. Tagging is
exception-driven — the user wants the twelve broken files out of five
thousand.

Start with a fixed set of built-in audit predicates in the existing filter
menu. Field-scoped search (`artist:Lynch`) and user-saved filters are the
follow-on, only if the built-ins prove too rigid.

### 2d. Saved actions (recipes)

The category's centre of gravity — Mp3tag's Action Groups, Yate's Actions,
Meta's derive/compose. An action is an **ordered list of `TagEdit`s plus a
name**, so 2a and 2b are its vocabulary and this step is mostly persistence
and a manager UI. Needs a dry-run preview with a per-step diff, and
import/export so a recipe can be shared.

Deliberately **not** a scripting language: `COMPETITION.md` records why —
Picard's is more powerful and generates a matching share of its support
traffic. Copy Mp3tag/Meta accessibility instead.

### ~~2e. Multi-artwork~~ — not being built

Ruled out, not deferred: the requirement is one canonical cover, and a second
embedded image no player shows is upkeep without benefit. See `DECISIONS.md`,
"One canonical cover, not an artwork gallery".

### 2f. CSV import and export

Export → edit in a spreadsheet → import back, which is the workflow Meta,
Kid3, Tag Editor 2 and TagScanner all ship. Doubles as the cheapest possible
backup of a whole library's tags. Import must diff-and-preview before writing,
exactly as the metadata wizard already does.

### 2g. Duplicate detection

Same track twice, by tags first (artist + title + duration within a
tolerance) and by content hash second. beets' prompts and MediaMonkey's
Duplicate Content view are both heavily used. Show the pairs and let the user
choose; never delete anything automatically.

### 2h. Per-file batch fetch (album and season) — **v1**

Today the wizard fetches one result and applies it to the whole selection —
right for one file, wrong for an album or a season folder, which is why music
currently withholds per-track fields (`MUSIC.md`) and TV applies one episode
to one file (`MOVIES_TV.md`). Both of those guards are correct, and both are
working around the same missing feature.

The fix pairs **each selected file with its own result**: match by track or
episode number parsed from the filename (`FilenamePattern` already does this),
fetch the album's or season's list once, then diff and write each file against
its own match. This is the single most valuable unbuilt feature and the one
every commercial tool in the survey has — Tag Editor 2 sells "entire season"
tagging, MetaX sells season batch flows, beets' whole importer is this.

It breaks the wizard's core "one result for the whole selection" assumption,
so it is its own project rather than a tweak to the episode picker. Build it
once, for both kinds, not twice.

### 2i. Resumable, parallel scanning

Tag reading is still serial (`ponytail:`-marked in `App.swift`): fine for
hundreds, visible at thousands. MediaMonkey's worst reviews are *precisely*
this — hangs every few hundred files with no resume. Move to a `TaskGroup`,
report progress per file, and make a long scan cancellable and resumable.

### ✅ 2j. Custom-tag visibility — done

Unknown atoms and frames round-trip as `TagKey.custom` — the lossless
invariant holds — but there is **no UI to see or edit them**. The developer's
Audible files carry a multi-kilobyte base64 blob and several private atoms
that cannot be inspected, and a wrong custom tag cannot be corrected at all.

v1 because the invariant is unverifiable without it: the app promises nothing
is dropped, and gives the user no way to check. Mp3tag's extended-tag panel
(⌥T) is the shape. The data is already in `TagSet`; this is a section in the
inspector plus add/edit/remove.

### ✅ 2k. Chapter boundary check in the UI — done

`ChapterBoundaryCheck` (`TagIO`) is built, tested and **unreachable**. It
found real defects in 16 of the developer's 50 audiobooks — marks sitting
seconds into a pause, so every skip replays dead air.

Per `AUDIOBOOKS.md` it reports a *shape*, not a verdict, because a correct
mark can sit on a spoken chapter announcement. So the UI is a summary line
beside each chapter row ("In a pause, 2.0s after the previous audio ended"),
never a pass/fail badge — and an action to nudge a mark to the start of its
pause, since `EditEngine.applyChapters` already makes that undoable.

### ✅ 2l. The wizard's kind write-back — done

`MetadataWizardModel.kind` is frozen at whatever the sidebar tab was when the
wizard opened, so a file can leave the wizard carrying TV-shaped fields while
the sidebar still files it under Movie. Two places holding one fact, able to
disagree — the exact inconsistency `MOVIES_TV.md`'s sixth pass argues against.

The full plan, including the open question about whether changing kind
mid-wizard resets the search, is "Finalist B" in `MOVIES_TV.md`. v1 because
it writes fields that contradict the file's own classification.

---

## 3. flac and ogg/opus

Vorbis comments — a simple `KEY=value` list, roughly 60 lines to read and write.
flac also has a `PICTURE` block for artwork. Lowest priority: no such files in
the developer's library yet.

---

## Not planned

- Cloud sync, streaming, playback, a library server.
- Watchmode / "where to watch" — streaming data, out of scope for a local tagger.
- Sandboxing / App Store distribution, unless the app is ever shipped to others.
