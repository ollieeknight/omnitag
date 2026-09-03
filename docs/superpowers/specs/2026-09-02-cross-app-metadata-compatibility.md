# Cross-app metadata compatibility — plan

Date: 2026-09-02. Status: proposed, not started.

## Why

Tested two real m4b files against OmniTag: one tagged by mp3tag + its Audible
plugin, one downloaded by Libation (which tags via the bundled "Tone" app).
Read every atom with `AtomicParsley -t` and with a direct AVFoundation
metadata dump, not just static code reading.

Two confirmed bugs and one confirmed missing behaviour:

- **Libation/Tone writes freeform `----` atoms under mean `com.pilabor.tone`**,
  not `com.apple.iTunes`. `MPEG4KeyMap.freeformPrefix` is hardcoded to
  `"itlk/com.apple.iTunes."` (`Sources/TagIO/MPEG4KeyMap.swift:61`), so the
  identifier AVFoundation actually reports — `itlk/com.pilabor.tone.SERIES` —
  never matches. Series, Subtitle, Language, and Book# are completely
  invisible in the Inspector for every Libation-downloaded book. Verified via
  a direct `AVURLAsset.load(.metadata)` dump against the real file.
- **mp3tag's Audible plugin writes `GENRE` uppercase as a freeform atom**,
  where OmniTag only recognises the canonical `©gen` atom for `.genre`.
  Case-sensitive matching in `key(for:)` (`MPEG4KeyMap.swift:95-108`) means it
  round-trips as an invisible `.custom("GENRE")` instead of populating the
  Genre field.
- **Narrator and Author are frequently empty** not because the data is
  missing, but because the community convention (confirmed via Mp3tag
  community threads and Audiobookshelf's own documented ffmpeg-based mapping)
  is to write narrator into Composer (`©wrt`) and lean on Artist/Album Artist
  for author, never touching `©nrt`/`©aut` at all.

Decision made with the user: **no redundant writes**. Cross-app atom
redundancy is invisible to any single app (each app only ever displays its
own field), so the only real risk is *OmniTag's own* Inspector showing the
same value twice — which redundant writing does not cause, but which sloppy
custom-tag surfacing already does. The fix is read-side: match freeform names
regardless of mean namespace and case, and fall back to the community-convention
atom only when the canonical one is empty. The writer is untouched.

## What this does not include

**"Take all" scrub-and-replace.** `docs/AUDIOBOOKS.md` documents Overwrite All
as replacing the tag set entirely and dropping anything the provider didn't
supply. `MetadataWizardModel.swift:210` shows it is actually "tick every field
the provider supplied," fed through `EditEngine.applySnapshot`
(`Sources/EditEngine/EditEngine.swift:149-172`), which only ever touches keys
present in the incoming delta — a key the file has and the provider didn't
return is never cleared. DRM/checkout cruft (`CDEK`, `AACR`, `VERS`, `prID`)
survives a "take all" untouched. This is a real gap against the documented
behaviour, but it is a different subsystem (`EditEngine`/write semantics, not
`TagIO`/read semantics) with its own design surface — deliberately a separate
follow-on plan, not bundled here.

**Movies/TV.** Light audit only, folded into Phase 3, not a redesign. Plex and
Infuse mostly resolve display metadata through external agents (TMDB) rather
than embedded file tags; VLC displays only the small set of standard atoms
OmniTag already supports. `MatroskaKeyMap.swift` already has
level-independent `NARRATOR`/`AUTHOR` name mappings (lines 33-34) with no
fallback logic of its own — same shape as the MPEG4 gap, smaller stakes.

## Phase 1 — MPEG4 read-fallback (audiobooks)

**Where the fix goes**: `Sources/TagIO/MPEG4KeyMap.swift`, specifically
`key(for:)` (lines 95-108) for freeform matching, plus a new fallback step in
`Sources/TagIO/AVTagReader.swift`, inserted after the `for item in metadata`
loop ends (line 48) and before `MediaItem(...)` is constructed (line 50) —
confirmed as the correct seam because `tags` is a plain, fully-populated
`TagSet` at that point and nothing downstream re-derives it.

1. **Mean-agnostic freeform matching.** In `key(for:)`, instead of requiring
   `raw.hasPrefix(freeformPrefix)`, match on everything after the *last* `.`
   in a `itlk/`-prefixed identifier, regardless of the mean string before it.
   `identifier(for:)` (write direction, lines 80-85) stays exactly as is —
   OmniTag keeps writing under `com.apple.iTunes`, per the no-redundant-writes
   decision; only reading becomes permissive.
2. **Case-insensitive freeform name lookup.** `keysByFreeform` (line
   75-76) is built once from `freeformNames`; add a normalised (uppercased)
   parallel lookup so `GENRE`/`Genre`/`genre` all resolve to `.genre`. Also
   add `.genre: "GENRE"` to `freeformNames` itself (line 42-52) — it is
   currently only reachable via the canonical `©gen` atom, which is why the
   mp3tag file's freeform copy is invisible even before the case-sensitivity
   question.
3. **Add the real `asin` fourCC atom.** Libation writes both a real `itsk/asin`
   atom and a freeform `ASIN` copy; only the freeform one is recognised today.
   Add `.asin: "asin"` to the `atoms` table (line 12-32) alongside the
   existing freeform entry — freeform stays the write target (line 46), the
   new atom entry is read-only value in practice since `identifier(for:)`
   checks `atoms` before `freeformNames` (lines 81-82), so confirm this
   doesn't flip what gets *written* for `.asin` — write a test asserting the
   writer still emits the freeform form only.
4. **Narrator/Author fallback**, applied once after the read loop in
   `AVTagReader.swift`:
   - `if tags[.narrator] == nil, let composer = tags[.composer] { tags[.narrator] = composer }`
   - `if tags[.author] == nil, let artist = tags[.albumArtist] ?? tags[.artist] { tags[.author] = artist }`
   (prefer Album Artist over Artist for author, since Album Artist is more
   often the single-author field while Artist sometimes carries
   `"Author, Narrator"` combined — confirmed in the mp3tag test file, where
   Artist was `"Dan Abnett, Toby Longworth"` and Album Artist was the correct
   `"Dan Abnett"` alone).
   This only ever fills an *absent* key — a file that already sets
   `.narrator` distinctly from `.composer` is never touched, so nothing here
   can override a deliberate distinction.

**Anti-pattern guard**: do not let the fallback value flow back into
`EditEngine.applySnapshot`'s delta (`EditEngine.swift:154`) as if it were a
real edit — it must stay a read-time/display-time value on the freshly-read
`MediaItem`, never written back unless the user explicitly edits that field
through the normal edit path. Since `AVTagReader.read` only produces
`MediaItem`s consumed by the UI, and `applySnapshot` only touches keys present
in whatever delta the wizard/inspector explicitly constructs, this holds
automatically as long as the fallback is not mistakenly added anywhere in the
write path (`MPEG4TagWriter.swift`, `EditEngine.swift`) — verify by grep after
implementation.

**Fixtures**: extend `Tests/TagIOTests/TwinPeaks.swift`. `diary` (lines 35-52)
is the existing audiobook fixture with narrator/author/series already set —
add sibling fixtures (or parametrised variants) for:
- an alternate-mean freeform atom (writing `.custom("mean.name")`-shaped keys
  is already supported by `MPEG4TagWriter.metadataItems` per
  `MPEG4KeyMap.swift:83`, so a fixture can exercise this without new writer
  code — check whether `TagKey.custom` values can currently express an
  arbitrary mean prefix, or whether the fixture needs to write via a raw
  `AVMutableMetadataItem` bypassing `MPEG4TagWriter`; resolve this at
  implementation time, it wasn't settled during fact-gathering)
- an uppercase freeform `GENRE` with no `©gen` atom present
- composer-only (no `©nrt`) — assert narrator fallback fires
- artist/album-artist-only (no `©aut`) — assert author fallback fires
- a file with both `.narrator` and `.composer` set to different values —
  assert no override happens

**Verification**: `make test` green. Manually re-run the AtomicParsley +
AVFoundation dump against both real test files (Desktop mp3tag file, Libation
Thousand Sons file) and confirm Series/Subtitle/Language/Book#/Genre/Narrator/
Author now populate in the Inspector for both, without touching either file
(read-only verification, never write to real media per `AGENTS.md` rule 6).

## Phase 2 — Books (EPUB/PDF) audit

Confirmed via full reads of `EPUBKeyMap.swift` and the PDF key map (in
`PDFTagIO.swift`, not a separate file as `docs/FORMATS.md`'s file-naming
convention might suggest):

- **Series already has the target pattern.** `EPUBKeyMap.swift:50-58` reads
  `package.meta(property: "belongs-to-collection") ?? package.legacyMeta(name: "calibre:series")`
  — a plain `??` fallback between EPUB3 and calibre/EPUB2 sources. This is
  the same shape Phase 1 is building for MPEG4; no change needed here, it's
  already correct.
- **Gap**: no `.narrator` mapping exists anywhere in EPUB — not in the
  Dublin Core table, not read anywhere in `tags(from:)`. `.author` reads only
  `dc:creator` with no fallback (e.g. to `dc:contributor` for a second
  credited person). `.subtitle` reads a single `allDC("title").dropFirst().first`
  with no calibre-style alternate. `docs/BOOKS.md`'s field table (lines
  18-30) documents none of these gaps either — the doc and the code agree,
  which at least means nothing is silently diverging.
- **PDF has no series/narrator/subtitle/isbn concept at all** — confirmed via
  `PDFKeyMap.attributes` (5 entries: title, author, synopsis, genre,
  publisher) plus year from `creationDateAttribute`. This is a real ceiling
  of `PDFDocumentAttribute`, not a gap to close — PDFKit doesn't expose more.
  No action.

**Task**: decide whether EPUB narrator is worth adding. EPUB has no
audiobook concept, so "narrator" is meaningless for a plain book — likely
skip. `dc:contributor` as an author fallback is cheap (same `??` pattern as
series) and matches real Calibre exports where a second contributor sometimes
carries co-author credit — worth adding if a real test file shows it in
practice; otherwise this phase may correctly conclude "no gap to close,"
which is a valid outcome per the original brief. Don't add speculative
fallback for a case with no confirmed real file exhibiting it.

**Verification**: if `dc:contributor` fallback is added, TDD via
`EPUBBuilder` (`docs/BOOKS.md:84-97` confirms this is the existing inline
fixture builder pattern, checked with `/usr/bin/unzip -t`). If no change is
made, this phase's output is the audit itself — record the "no gap found"
conclusion in `docs/STATUS.md`/`docs/BOOKS.md` so it isn't re-investigated
later.

## Phase 3 — Movies/TV light audit

Not a redesign. Check `MatroskaKeyMap.swift`'s existing `NARRATOR`/`AUTHOR`
level-independent names (lines 33-34) and `MPEG4KeyMap`'s video-relevant keys
(`.showName`, `.seasonNumber`, `.episodeNumber`, `.episodeTitle`, `.director`,
`.studio`, `.contentRating`) against what VLC actually surfaces (title,
artist, album, genre, year — the standard atom set, already fully supported)
and what Plex/Infuse read from embedded tags versus their TMDB agents.

**Task**: a short research pass (web search, same approach as the audiobook
investigation) confirming whether Plex/Infuse read any embedded MKV/MP4 tag
at all when an agent match exists, or whether embedded tags only matter as a
fallback when no online match is found. If the latter (expected), this phase
concludes with no code change — embedded-tag fragmentation matters far less
here than for audiobooks, since the primary consumers don't rely on it.
Only escalate to an implementation phase if the research turns up something
concrete and cheap (e.g. a single missing name-table entry, same shape as
Phase 1 item 2).

## Verification (all phases)

- `make test` green throughout — TDD per `AGENTS.md`, Swift Testing not
  XCTest, no network in tests except opt-in `LiveAPITests`.
- Reader/writer key-table discipline: confirm no phase adds a key to one side
  only. Phase 1 is deliberately read-only (fallback + permissive matching);
  grep `Sources/TagIO/MPEG4TagWriter.swift` and `Sources/EditEngine/` after
  implementation to confirm no fallback logic leaked into the write path.
- Update `docs/STATUS.md` (add to "Works today" table once shipped, or "Does
  not work yet" while in progress) and tick `docs/ROADMAP.md` in the same
  commit as the code, per `AGENTS.md`'s house rule — do this per phase, not
  only at the end.
- Never write to real media in a test (`AGENTS.md` rule 6) — verification
  against the two real files on disk (Desktop, Libation library) is read-only
  confirmation after the fixture-based tests pass, not a substitute for them.

## Explicitly deferred (separate plan)

"Take all" scrub-and-replace in `EditEngine`/`FileTagWriter` — needs its own
design pass: what counts as "known" for clearing purposes, how custom/freeform
atoms get enumerated and cleared safely, and how it interacts with undo/redo.
Not started here.
