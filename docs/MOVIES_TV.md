# Movies and TV

TMDB (The Movie Database), the movie and TV half of roadmap item 1. The
design is in `superpowers/specs/2026-09-03-tmdb-provider-design.md`. Done:
`TagKey.tmdbID`, `TMDBKeyStore`, `TMDBClient`, `TMDBProvider`, the
Preferences pane, and the wizard's episode picker — verified against the
real API and the developer's own Twin Peaks movie and S01E01 file. See
`STATUS.md` for the exact line.

## Why TMDB

The only free, community-run catalogue with movie *and* TV coverage,
episode-level detail, and posters — the same source most local media taggers
(Plex, Jellyfin) use. Apple has no public metadata API for movies/TV
(iTunes Search only covers music). TVmaze is TV-only and thinner; it stays a
fallback for if TMDB's episode data proves thin, not a starting choice.
Watchmode ("where to watch") is permanently out of scope, per `DECISIONS.md`
— OmniTag tags local files, it does not tell you where to stream them.

TMDB requires a free API key, unlike every provider OmniTag has integrated
so far.

## The key

Set once, in the app's Preferences window (`Settings` scene), and stored in
the Keychain (`kSecClassGenericPassword`, service `omnitag.tmdb`) — never in
the binary, never in the repo, never in a test fixture. `TMDBKeyStore` is a
direct wrapper over `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`/
`SecItemDelete`; no third-party Keychain library, per `DECISIONS.md`'s "no
dependencies" rule.

If no key is set, TMDB still appears in the wizard's provider menu for movie
and TV tabs — hiding it would look like a missing feature, not an unset
preference — but a search returns a clear "add your TMDB key in Preferences"
error rather than a network failure.

## Provider shape

One `TMDBProvider`, `kinds = [.movie, .tvEpisode]`, the same pattern as
`AudibleMetadataProvider` covering one kind and `OpenLibraryProvider`
covering another. TMDB's own API is two endpoints (`/search/movie`,
`/search/tv`); which one `TMDBProvider.search` calls is decided by the kind
the wizard is running for, never guessed from the result — the wizard already
threads `MediaKind` through `MetadataProviders.serving(kind)`, so the
information is already there. `/search/multi` (TMDB's combined endpoint,
mixing movies, TV and people in one response) was considered and rejected:
it would need extra filtering to drop people and re-derive the kind from
each hit, solving a problem the tab selection has already solved.

## Movies

Search → candidate → `details(for:)` fetches immediately, same one-step flow
Audible and OpenLibrary already use. A movie's `MetadataRecord` fills
`TagKey.title`, `.year`, `.director`, `.studio`, `.genre`, `.contentRating`,
`.synopsis` — every one of these already exists in `Tags.swift`'s
`standardFields(for: .movie)`; TMDB needed no new domain vocabulary for
movies.

## TV: the two-step candidate

A TMDB TV search result identifies a **show**, not an episode — there is no
single ID that names "Twin Peaks S01E01" the way an ASIN names one specific
audiobook. So the wizard's TV flow is two steps where the audiobook and book
flows are one:

1. **Search** returns shows. Picking one calls `details(for:)`, which
   returns the **show-level** `MetadataDetails` — no episode chosen yet.
2. A new wizard step, **Episode** (`WizardStep.episode`, `EpisodePickerView`),
   appears only when `kind == .tvEpisode` and the candidate is a TV show —
   the same conditional-inclusion mechanism `.chapters` already uses in
   `MetadataWizardModel.steps`. It offers a season selector, fetches that
   season's episode list from `/tv/{id}/season/{n}`, and picking one calls
   the episode-resolving detail path, which produces the final
   `MetadataDetails` for that specific episode: `.showName`, `.seasonNumber`,
   `.episodeNumber`, `.episodeTitle`, `.year` (air date), `.synopsis`, and
   `.director` where TMDB has it.

Everything after that — tag diff, artwork download, apply, undo — is
unmodified: a TV episode's `MetadataDetails` is just another value flowing
into the same `TagDiff` and `buildSnapshot()` every other kind uses.

## Shared with audiobooks, and what wasn't

The tag-diff table, clean-overwrite toggle, artwork download, apply and undo
are all generic — keyed on `TagKey`, not media kind — so movies and TV get
them for free once `MetadataDetails` is populated. Two gaps surfaced while
wiring TMDB in, both fixed:

- **mkv cannot store artwork** (`MatroskaTagWriter.write` has no artwork
  parameter — see `STATUS.md`'s "does not work yet"). Since most movie/TV
  files here are mkv, a downloaded poster would previously vanish with no
  error. `MetadataWizardModel.canWriteArtwork` checks
  `MediaTagReader.canWriteArtwork` for the whole selection; when false, the
  cover is never downloaded, and the summary step says so — the same
  pattern the chapters step already used for "chapters skipped."
- **The summary pane's byline showed nothing for a movie.** It read
  `authors`, which only audiobooks and books populate. `MetadataRecord.
  byline` now falls back through authors → narrators → director → show
  name, so every kind shows something recognisable under the title.

Alternative considered: encode season/episode into the search query upfront,
so `candidate.id` already names one episode. Rejected — it would force
guessing episode numbers before seeing any search results, and it breaks the
existing "candidate id is a provider-scoped opaque string" contract every
other provider relies on.

## The TMDB ID

`TagKey.tmdbID`, new alongside `.asin`/`.isbn`, written into
`MetadataRecord.tagSet` for both movies and TV episodes. Same reasoning as
the audiobook and book providers: persisting the provider's own ID means a
later "refresh this file's metadata" can go straight to the known ID instead
of searching again, and third-party tools that already look for a TMDB id
tag (Plex, Jellyfin) find one.

A TV episode's `tmdbID` is the episode's own TMDB id, not the show's — every
episode of a season needs a distinct id or "refresh" can never tell them
apart. (Review pass, 2026-09-03: the first build wrote the show ID for every
episode; fixed in `TMDBClient.EpisodeDetail`, see `TMDBClientTests`.)

`.tmdbID` must be wired into `MPEG4KeyMap` and `MatroskaKeyMap` like every
other video key, or the writer silently drops it (`guard let identifier =
... else { continue }`). It was not, in the first build — the key existed
on `TagKey` and was added to `MetadataRecord.tagSet` and `standardFields`,
but had no atom/freeform mapping, so it round-tripped as nothing on both mp4
and mkv. Fixed in the review pass; see `MPEG4KeyMapTests.tmdbIDHasWriteTarget`
and `MatroskaWriterTests.roundTripsTMDBID`.

## Two more fixes from the review pass

`MetadataRecord` now carries an explicit `kind: MediaKind` rather than
guessing movie/TV-ness from whether `director`/`studio`/`contentRating`/
`showName`/`seasonNumber`/`episodeNumber` happened to be set. That guess had
a real hole: a movie with no credited director, no production company and
no US content rating (a plausible foreign or unrated title) fell through it
and wrongly got `.album` written. Every provider now states its kind
explicitly at construction — see `MetadataRecordTests.
movieWithNoCreditsStillGetsNoAlbum`.

The wizard's episode picker (`MetadataWizardModel.canPickEpisode`) is now
gated to a single-file selection, mirroring `canWriteChapters`'s exact
reasoning: one episode's season/episode number and title cannot correctly
apply to more than one file. Selecting several TV files and running the
wizard now offers the show-level fields (name, year, genre) instead of
silently writing one episode's data onto every file in the selection.

## Testing

`TMDBClientTests`: stubbed `HTTPTransporting`, one test per client method —
movie search, TV search, movie detail, show detail, episode detail — plus
the failure paths: no key configured, non-200 status, malformed response.
Same style as `AudnexusClientTests`/`OpenLibraryClientTests`: no live
network, no mocked filesystem.

`TMDBKeyStoreTests`: round-trips a real Keychain item under a
test-scoped service string, deleted in teardown. Not stubbed — the Keychain
is a system framework, and `AGENTS.md`'s "no mocks for the filesystem" rule
applies here the same way.

`OMNITAG_LIVE=1` adds a TMDB check to the existing `LiveAPITests`, reading
the key from an environment variable that is never committed and never
required for `make test`. Run with both `OMNITAG_LIVE=1` and
`OMNITAG_TMDB_KEY=<your key>` set — the suite is skipped entirely if either
is missing, so a normal `make test` never needs one.

## Third pass: byline gap, TMDB error body, season 0

- **`MetadataCandidate.byline` was blank for every movie/TV search
  result.** `MetadataRecord.byline` (the summary pane) got a fallback in
  the second pass; `MetadataCandidate.byline` (the search-result card, a
  different type) did not. TMDB's `/search/movie` and `/search/tv`
  responses carry no director/cast at all — `MovieSummary.candidate` and
  `TVSummary.candidate` never populate `authors`/`narrators` — so a
  data-level fallback would have nothing to fall back to. Fixed at the
  view level instead, matching the pattern `bookSummaryPane` already used
  (`if let byline, !byline.isEmpty`): `searchGridCard` and
  `searchListRow` in `MetadataWizardView.swift` now hide the byline line
  entirely when it is empty, rather than reserving blank space for it.
  The two cards' accessibility labels ("Title by Byline") also got a
  guard so VoiceOver does not read a trailing "by" with nothing after it.
  UI-only change — no test target for `OmniTagApp` (see below); verified
  by reading the render path end to end and confirming `MovieSummary`/
  `TVSummary` decode no people fields, then by `swift build` succeeding.

- **`TMDBClient` discarded TMDB's own error body on a bad request.**
  Flagged in the second pass, not fixed then. A 401 became
  `MetadataError.server(status: 401)` with no message, even though TMDB
  returns `{"status_code":7,"status_message":"Invalid API key: ..."}`.
  `MetadataError.server` gained an optional `message: String?` (default
  `nil`, so every other call site — OpenLibrary, Audible, Audnexus,
  ArtworkDownloader — is unaffected); `TMDBClient.get` now attempts to
  decode that body and attaches the message when present. Test-first:
  `TMDBClientTests.serverErrorCarriesTMDBMessage` stubs a 401 with TMDB's
  real error shape and asserts on the resulting `.server(status:message:)`.

- **The episode picker's season stepper could not reach season 0**
  (TMDB's convention for specials). Flagged in the second pass, not fixed
  then. `TMDBClient.seasonEpisodes`/`episodeDetails` build the season
  number straight into the URL path with no lower-bound check, so season
  0 already worked end to end — only the UI's `Stepper(... in: 1...50)`
  blocked it. Changed to `0...50` in `MetadataWizardView.episodeStep`.
  `selectedSeason` still *defaults* to 1 (unchanged), so specials stay
  opt-in rather than the first thing shown. UI-only; verified by reading
  `TMDBClient`'s URL construction (no season-number validation anywhere)
  and `swift build`.

## Checked this pass, not changed

- **Content rating / genre as plain tag-table rows.** Confirmed: `.contentRating`
  maps to a string tag ("Rating" label, e.g. "R", "TV-MA") with no special
  UI treatment, same as every other field. Reads fine as plain text; no
  gap.
- **`TMDBClient`'s modeled fields vs a real TMDB response.** Pulled TMDB's
  documented response shape for `/movie/{id}` and `/tv/{id}` (no live key
  available in this environment, so via TMDB's published API reference,
  not a live call). Unmodeled fields with no existing `TagKey` home:
  `imdb_id`, `vote_average`, `runtime`, `original_language` (movie);
  `vote_average`, `status`, `episode_run_time`, `original_language`,
  `number_of_seasons/episodes` (TV). Adding any of these means a new
  `TagKey` case plus `MPEG4KeyMap`/`MatroskaKeyMap` wiring on both sides
  (`AGENTS.md`'s "reader and writer share one key table" rule) — real
  scope, not a one-line addition, and this is the second review pass to
  reach that conclusion. Left as a flagged follow-up, not built.

## Fourth pass: a real OmniTagApp test target, and the TMDB type-check it replaced

The "no test target for `OmniTagApp`" gap named in the second and third
passes above is fixed: `OmniTagAppTests` (`Package.swift`) can now
`@testable import OmniTagApp`, and `Tests/OmniTagAppTests/
MetadataWizardModelTests.swift` drives `MetadataWizardModel` directly
against a fake `MetadataProvider` — no network, no view rendering, no
Keychain. Ten tests cover the exact boundary this file's "shared with
audiobooks" section describes: `buildSnapshot()`'s mkv-artwork skip, the
multi-file chapter/episode guards, `skipChapters` actually suppressing the
write (not sending an empty list, which would erase a file's own
chapters), merge mode never clearing an unmentioned field, and the TV
show-vs-episode routing decision.

Writing the routing test surfaced a design smell worth fixing on its own:
`select(candidate:)`'s TV branch checked `provider is TMDBProvider`, a
concrete-type check with nothing to substitute in a test — there is no way
to fake "is a TMDBProvider" without being one. `MetadataProvider` gained
`var hasEpisodePicker: Bool { get }` (default `false` via the protocol
extension every other provider already relies on), `TMDBProvider` overrides
it to `true`, and `select(candidate:)` now asks the provider rather than
naming it. Same behaviour, testable against `FakeProvider(hasEpisodePicker:
true)` without a real network or Keychain dependency — see
`EpisodeSelectionTests` in the new test file.

## Flagged for the developer, not verified this pass

Both need a live TMDB key or interactive clicking through the app,
neither available to this session (no key in Keychain or environment,
headless agent, no GUI):

- **Search ranking quality** (`TMDBProvider.search` sends `query.searchTerms`
  only, no client-side ranking the way Audible's `searchLadder`/`score`
  do). TMDB ranks by popularity server-side, which is plausibly enough,
  but unverified against a real ambiguous query ("It", "Up", a common show
  title).
- **Same-title disambiguation legibility** — e.g. "The Office" UK vs US.
  Year is shown in both grid and list views, which should disambiguate on
  paper; not confirmed to actually read well side by side in the running
  app.

## Fifth pass: a simulated first-time user, and three real fixes

A session simulated a first-time user adding `~/Desktop/tp` (a mixed
music/movie/TV/audiobook/book folder) and clicking through cold, with no
prior context — the trigger was the developer's own description of hitting
exactly this: "I add a file, why has it disappeared? Oh, I'm on the Music
tab and need to swap to Movies." That session had no working Accessibility
access to actually drive the app (confirmed and reported honestly rather
than faking a click-through), so it traced the same paths through code
instead. Three findings led to fixes, applied directly afterward:

- **No signal when a mixed scan fans out across tabs.** Confirmed: `visible`
  correctly filters by the active tab (nothing is actually lost), but
  nothing told the user *where* the other files went — no sidebar count, no
  toast, just a status-bar total. Fixed: `LibraryModel.count(for:)` plus a
  per-kind badge in the sidebar (`LibraryView.swift`), so adding a mixed
  folder from any tab shows at a glance how many landed where.

- **`detectKind` trusted the active sidebar tab for ambiguous video files.**
  A folder scanned while sitting on the TV tab could silently file an
  unrelated, ambiguously-named movie as a TV episode — `defaultKind` was
  the current tab, not a neutral default. Fixed: an ambiguous video file
  (no SxxExx pattern) now always defaults to `.movie`, tab-independent.
  `detectKind` widened from `private` to internal so `OmniTagAppTests` can
  exercise it directly. See `LibraryModelTests.DetectKindTests`.

- **Episode-picker Back skipped past itself.** Flagged three times running
  now (this is the pass that finally fixed it) — after picking an episode,
  `.episode` was removed from `steps` entirely, so `retreat()` from `.tags`
  landed on `.search`, silently losing the picked show and episode both
  with no warning that Back meant something different here than everywhere
  else in the wizard. Fixed: `awaitingEpisodeChoice` (gone) is replaced by
  `isEpisodeFlow`, which stays true for the life of a TV candidate's flow
  regardless of whether an episode has been picked — `.episode` now stays
  addressable by Back the whole time. See `MetadataWizardModelTests.
  backAfterPickingEpisodeReturnsToEpisodeStep`.

All three: TDD, `make test` green throughout (289 → 298 tests), nothing
committed.

### A bigger question raised, not yet designed

Fixing the tab-trusting classifier surfaced a real design question from the
developer: the wizard's own first step already has an explicit movie-vs-TV
choice built in (which TMDB endpoint gets searched), and that's a *second*,
disconnected mechanism from "which sidebar tab is this file assigned to."
Two separate systems decide kind today — the auto-classifier plus manual
sidebar drag, and the wizard's own kind selection — with no relationship
between them. Whether the kind-assignment UI as a whole deserves a rethink
is an open question, not answered here; see whichever session picks it up
next for the actual design work.

## Sixth pass: kind-assignment design, and Finalist A shipped

The "bigger question" above got a proper design exploration: a session
using a UI/UX-focused skill generated five concepts for how a file's
`MediaKind` should be assigned, shown, and corrected, cut three, and
presented two finalists with concrete interaction models and honest
tradeoffs. Full writeup published as an artifact (ask the developer for the
link if the design detail below isn't enough — this doc keeps the decision
and the plan, not the full exploration).

Cut, briefly:
- **Import review sheet** (Jellyfin/Plex-style: confirm classification
  before files are added). Wrong cost/benefit for a tool you re-run on the
  same folder repeatedly, batch-editing already-organized libraries rather
  than importing once.
- **Sidebar tooltip + context-menu reassign.** Insufficient alone — fixes
  discoverability but not the actual three-way disconnect (auto-classify,
  drag, wizard) — but worth doing as a cheap add-on regardless of which
  finalist ships. Not done in this pass; still open.
- **Merge Movie/TV into one Video tab.** A real idea — they already share a
  provider and a container family — but bigger blast radius than justified
  now: touches `visible`'s filter, the table's per-kind column sets, and
  the empty state, all at once.

Two finalists, and a follow-up discussion with the developer about how
Apple's own apps (Finder, Photos, Music/TV's Get Info) actually handle this
— the throughline there: kind is treated as a **fact to display and edit
inline**, never a separate "assignment" ritual, and a stale second opinion
of the same fact in two places is exactly the kind of inconsistency to
avoid.

### Finalist A — shipped this pass

Turned out the inspector already had a persistent "Kind" `Picker`
(`InspectorView.kindSection` in `LibraryView.swift`) bound to `setKind` —
so the finalist's actual gap was narrower than first scoped: not a new
control, but the missing **"why"**. A file's kind is sometimes a guess
(`LibraryModel.detectKind`'s SxxExx-or-movie fallback for ambiguous video),
and nothing explained that guess at the point where a user might want to
correct it.

Added: `LibraryModel.kindGuessReason(url:kind:)`, a pure function
alongside `detectKind` re-deriving *why* a video file landed where it did
— `nil` for every kind with nothing ambiguous to explain (m4b, epub/pdf,
music: extension alone decides, no guess involved). Shown as a small
secondary caption under the Kind picker, only for a single-item selection
(a multi-selection's items were classified independently and may have
different reasons, so one caption can't speak for all of them).

TDD, `make test` green throughout (298 → 301 tests). See
`LibraryModelTests.KindGuessReasonTests`. Not committed.

**Get Info considered, decided against.** Discussed as a possible future
surface (⌘I / right-click, matching Music/TV/Finder's own pattern) before
this pass, then explicitly ruled out: in those apps Get Info is a
single-item deep-dive covering everything about one file, of which kind is
just one field among many — it earns its place there because browsing a
media library means occasionally correcting one file's metadata. OmniTag's
whole design centre is the opposite: batch-editing, select many files and
type once, which is exactly what the inspector already does well. A Get
Info window whose only real job was "let me change the kind" would just be
a second, more ceremonious way to do what the inspector's Kind picker
already does inline — genuinely redundant, not merely deferred. Revisit
only if a concrete need shows up that the batch inspector structurally
can't serve (e.g. inspecting a file's raw custom/unmanaged tags without
cluttering the main batch UI) — not as "kind editing, but fancier."

### Finalist B — plan, not yet built

**The problem B solves**: `MetadataWizardModel.kind` is a `let`, frozen at
whatever the sidebar tab was when the wizard opened (`MetadataWizardView.
init(items:kind:applyAction:)` → `MetadataWizardModel.init`). If a user
picks "TV" inside the wizard's own implied choice (which is really just
"which tab was active"), that never writes back to the file's actual
`MediaKind` — so a file can walk away from the wizard tagged with TV-shaped
fields while the sidebar still files it under Movie, or vice versa. Two
places holding the same fact, capable of disagreeing, is the exact
inconsistency Apple's own pattern above argues against.

**What "fixing" it means, concretely:**

1. `MetadataWizardModel.kind` changes from `let` to a settable `var`. Every
   place that reads it today (`search()`'s `provider.search(query, kind:
   kind, ...)`, `select(candidate:)`'s TV-branch check, `steps`, the
   summary tile's field labels via `TagDiff(kind: self.kind)`) needs to
   react correctly if it changes mid-wizard, not just at construction.
2. Somewhere in the wizard's search step, movie-vs-TV needs to become an
   explicit, visible choice the user makes — not implied by which sidebar
   tab happened to be active before opening the wizard. (This might look
   like a segmented control next to the search field, shown only when
   `selectedItems` are movie/TV-eligible; exact UI is undesigned — this
   plan describes the model-layer change, not the view.)
3. When the wizard's kind choice differs from `selectedItems`'s actual
   `MediaKind`, applying the wizard's result must also call `LibraryModel.
   setKind` (or the `EditEngine` equivalent) as part of the same undoable
   batch — the wizard's kind becomes authoritative, closing the
   disagreement, rather than the two silently drifting apart.
4. **Real scope, not a quick edit**: `kind` going mutable touches
   `canPickEpisode` (currently checks `selectedItems.count == 1`, would
   also need to react to a kind *change* mid-flow), the episode-flow gate
   (`isEpisodeFlow`, `steps`'s conditional inclusion of `.episode` — does
   switching from Movie to TV mid-search need to retroactively show the
   episode step?), and every multi-file guard that currently assumes
   `kind` is stable for the wizard's whole lifetime. Each of these needs
   its own TDD pass in `OmniTagAppTests`, the same way `hasEpisodePicker`
   and `isEpisodeFlow` did.
5. **Open question, not resolved by this plan**: does changing kind
   mid-wizard reset the search results (a TMDB movie search and a TV
   search are different endpoints entirely), or does it need its own
   "are you sure, this will restart your search" confirmation? Needs a
   decision before implementation starts, likely via the same brainstorm
   process (`AGENTS.md`'s skill table) that produced this plan.

**Recommended order if picked up**: brainstorm/design the visible
movie-vs-TV choice in the search step first (item 2), since that shapes
what "kind changes mid-wizard" actually needs to support; then do the
model-layer change (items 1, 3, 4) test-first against that settled
interaction; resolve item 5 as part of the same design pass, not as an
afterthought during implementation.

## Seventh pass: mkv artwork writing closes the gap from the first pass

The gap flagged at the top of this doc — "mkv cannot store artwork" — is
fixed: `MatroskaTagWriter.write` takes an `artwork: [Artwork]` parameter and
writes one `AttachedFile` per cover into `Attachments`, patched in place by
the same three-case layout logic (`Tags` and `Attachments` are independent
top-level elements, each with its own `Void` slack and `SeekHead` entry — a
tag-only write never touches an existing cover). See `FORMATS.md` for the
byte-level detail. `MediaTagReader.canWriteArtwork` now includes `.mkv`, so
`MetadataWizardModel.canWriteArtwork` and the summary step's "artwork will be
skipped" warning both fall away for mkv on their own — no wizard code
changed. TDD: `MatroskaWriterTests` gained three cases (fresh file, replacing
an existing cover alongside unrelated tags, and empty artwork being a no-op
rather than clearing the existing cover); `MetadataWizardModelTests
.mkvNeverGetsArtwork` — asserting the old gap — flipped to
`mkvGetsArtwork`, asserting the fix. `make test` green throughout
(311 → 314 tests). Not committed.

## Eighth pass: mkv chapter writing, and no chapter-fetch API exists for movies/TV

Before building this, checked whether a free/community API for movie/TV
chapter data (scene markers, act breaks) exists the way TMDB serves metadata
and Audnexus serves audiobook chapters. It does not, and structurally can't:
chapter markers are a DVD/Blu-ray authoring artifact, not published or
catalogued editorial content anywhere — Plex/Jellyfin only ever read what a
rip already embeds (from `MakeMKV` et al.) or generate their own local scene
markers, never fetch them. So mkv chapter support here is purely local
editing of chapters already in the file, via the inspector — never a wizard
step, since there is nothing for a provider to search for.

`MatroskaTagWriter.write` gained `chapters: [Chapter]? = nil`, writing a
single default `EditionEntry` (OmniTag's `Chapter` model has no concept of
multiple editions, matching what `MatroskaReader` already flattens every
edition into on read) via the same generalized element-patch machinery
`Tags` and `Attachments` use. `nil` leaves existing chapters alone; an
explicit `[]` deletes all of them — mirroring the contract `MediaTagReader
.write` already used for mp4's `MPEG4ChapterWriter` branch. `MediaTagReader
.canWriteChapters` is new (mp4-family + mkv; not mp3/epub/pdf), wired into
the inspector's chapter section so a format whose chapters are read-only
shows the list without edit controls instead of silently discarding edits
on save.

Generalizing `MatroskaTagWriter`'s single-element patch logic to a third
element surfaced a real bug affecting all three: an element's "am I last in
the file?" check compared against the *original* file length, not the
current projected end-of-file. Writing two elements that both need to
relocate in the same call (e.g. a bigger `Tags` and a bigger `Chapters`
together) could silently corrupt the file, because the second element's
stale "last" check would overwrite it in place at an offset that was no
longer actually the end of the file. Fixed by comparing against
`plan.newLength ?? plan.fileLength`; caught by a test that grows both `Tags`
and `Chapters` past their original regions in one write. See `FORMATS.md`
for the byte-level detail.

TDD throughout; `make test` green (314 → 319 tests). Not committed.

## Ninth pass: mkv subtitle track metadata

The next item after mkv chapters: subtitle track editing. Scoped down hard
during brainstorming before any code — an mkv subtitle track is carried as
`SimpleBlock`s inside Clusters, the one region `MatroskaTagWriter`'s whole
design deliberately never touches (that's how it patches a 6 GB file in
milliseconds); adding or removing a track means rewriting every Cluster's
block structure, a real remux. So this pass edits **metadata on tracks
already in the file** — language, track name, default/forced/enabled flags —
never mux, never touch cue payloads, never ASS/SSA style headers (those live
inside the track's own data, not its metadata).

New `SubtitleTrack` (`MediaCore`), identified by its `TrackUID` — the file's
own permanent identity, not file-order position, since edits must survive a
different read order and any future add/remove work. `MatroskaReader` gained
`walkTracks`, filtering `TrackType == 17` (subtitle) out of the previously
entirely-skipped `Tracks` element; `LanguageBCP47` wins over the legacy
`Language` field when both are present, and an empty `Name` reads as `nil`,
not `""`.

The writer is the one place this breaks from Tags/Attachments/Chapters'
pattern: those three are fully regenerated from OmniTag's own model on every
write, but `Tracks` also holds video/audio TrackEntries and per-track binary
blobs (`CodecPrivate`) that must round-trip byte-for-byte per `AGENTS.md`'s
lossless invariant. `MatroskaTagWriter.patchTracks` walks the *existing*
`Tracks` body instead: an untouched TrackEntry (video, audio, an unedited
subtitle track) is byte-copied whole; inside a matched entry, only the six
known fields are replaced, every other child — including `CodecPrivate` —
survives untouched. An edit whose `TrackUID` matches nothing in the file is
silently dropped, never inserted as a phantom track. `Tracks` then plans
through the same generalized `planElement`/`Layout.slot(for:)` machinery as
Tags/Attachments/Chapters — a fourth independent top-level element.

Full loop shipped in one pass: reader, writer, `MediaTagReader
.canWriteSubtitleTracks` (mkv only), `EditEngine.applySubtitleTracks`
(single-file, undoable, wired into `save()`/`Snapshot`/`dirtyURLs` exactly
like chapters), and an inspector section (`SubtitleTrackRow`: language/name
fields, three checkboxes, no add/remove UI since none is supported).

Tested against the developer's own real files, not just synthetic fixtures:
the S01E01 episode (one untagged SRT track) and the film (one tagged SRT
plus three PGS/bitmap tracks from the Blu-ray, no text or style data at all —
reinforcing that track-metadata-only was the right scope, since font/style
editing wouldn't even apply to most subtitle tracks in a real library).
`make test` green throughout (319 → 333 tests). Not committed.

### Considered and ruled out before writing code

- **Full track mux (add/remove)** — real remux territory (see above); a
  stream-copy remux is I/O-bound and cheap in principle (no re-encoding), but
  real engineering (Cluster block rewriting or shelling out to a muxer), and
  a separate project from metadata editing. Not started.
- **ASS/SSA style header editing** (`[V4+ Styles]` font/size/color) — lives
  inside the track's own cue data, not its `TrackEntry` metadata; editing it
  means parsing and rewriting blocks inside Clusters, the exact remux risk
  ruled out above. The real film's PGS tracks have no such header at all
  (bitmap subtitles), underlining that this would only ever help a minority
  of real tracks.
- **Sidecar subtitle files** (`.srt`/`.ass` next to the video) — the user
  specified mkv-embedded tracks only; sidecar files are a different, simpler
  problem (no container parsing at all) not asked for this pass.

## Follow-up: a season batch fetcher

Not built. Today the wizard picks one show → one episode and applies it to
every selected file — right for a single episode, wrong for a season
folder. A season-batch mode would use `FilenamePattern` (already parses
`%season%`/`%episode%` out of a TV filename, see `FILENAMES.md`) to pair
each selected file with its own episode number, fetch the season's episode
list once via `TMDBProvider.seasonEpisodes`, and diff+write each file
against its matched episode rather than broadcasting one result to the
whole selection. This changes `MetadataWizardModel`'s core "one result for
the whole selection" assumption, so it is scoped as its own follow-up
rather than folded into the single-episode picker above.

## Tenth pass: a bug hunt and a streamlining pass over the movie/TV path

A read-the-docs-then-hunt pass over the whole movie/TV journey, from adding a
folder to writing tags on the developer's real 6.5 GB film. Nine bugs and
seven streamlining changes, all TDD, `make test` green throughout (333 → 357
tests). Verified against the live TMDB API and both real mkv files.

### Bugs fixed

- **A TV episode's `Title` tag was written as `"Show — Episode"`.**
  `EpisodeDetail.record` built a composite title, which `MetadataRecord
  .tagSet` then wrote straight into `TagKey.title`. Every player that shows
  the series alongside the title (Plex, Infuse, Apple TV) reads that
  doubled. `title` is now the episode's own name; the show already had its
  own field in `showName`. See `TMDBClientTests.episodeTitleIsNotComposite`.

- **`standardFields(for: .tvEpisode)` listed neither `.title` nor
  `.synopsis`**, although TMDB returns an overview for every episode and
  `tagSet` writes it. The field appeared in the wizard's diff only because
  `TagDiff` unions the proposed keys — unlabelled and sorted into the
  alphabet. Both added.

- **Selecting a show while a non-default season was showing fired two
  fetches for one list.** `selectedSeason`'s `didSet` started a `Task` and
  `select(candidate:)` then called `loadSeasonEpisodes()` explicitly, so
  setting the season back to 1 raced two requests to set
  `episodeLoadState`. The `didSet` is gone; the episode step's
  `.task(id: selectedSeason)` is now the single trigger, and
  `loadSeasonEpisodes` early-returns when the list on screen is already the
  one being asked for (so stepping Back into the picker costs nothing).

- **Picking a second show showed the first show's episodes** until the new
  fetch landed — `episodeLoadState` was never reset between candidates.
  Now cleared to `.idle` alongside the season. See
  `EpisodePickerStateTests`.

- **`detectKind` ran twice for every file added individually** — once
  inline in `load(urls:)`'s single-file branch, then again in the loop that
  classifies everything. The inline call is gone; the loop is the one place
  a kind is decided.

- **The wizard's tag table rendered `.tmdbID` as "Tmdb Id"**, deriving every
  label from the enum case name by camel-case splitting while
  `standardFields` already carried a hand-written "TMDB ID". `TagKey.label
  (for:)` is new in `MediaCore` and reads `standardFields`; the wizard's
  private version now calls it.

- **The inspector kept its own copy of the per-kind field table** and had
  already drifted from `standardFields` (no `.tmdbID` anywhere, no `.title`
  for TV). Deleted; `InspectorView.fields` is now
  `TagKey.standardFields(for: model.kind)`.

- **A formatter regression, caught by its own test.** The release-noise
  regex was first written as a multi-line raw string with `\` line
  continuations; `swiftformat` strips those, which silently injected
  literal spaces into the middle of the alternation and left every term
  but the first two matchable only with padding. Rebuilt as a joined
  array of terms, and `allReleaseTermsStrip` now asserts each term
  individually.

- **Stale comment** on `LibraryModel.kindHasProvider` still said movies and
  TV had no provider.

### Streamlining

- **A scene-release filename now searches successfully as it stands.**
  `cleanedFilename` only ever stripped audiobook noise, so
  `Twin.Peaks.S01E01.Northwest.Passage.1080p.BluRay.x265-GROUP.mkv` reached
  TMDB verbatim and matched nothing. It now cuts everything from the
  `SxxEyy`/`NxM` marker onwards (that is the episode title and the release
  group, and TMDB's TV search wants the show), strips resolution/source/
  codec/audio/edition terms, and drops a trailing release year.

- **The filename's own season and episode are used, not thrown away.**
  `MetadataQuery` gained `season`, `episode` and `year`, scraped by
  `videoParts`. The episode picker opens on the season the file names
  rather than always season 1, and marks the matching episode with a
  "From filename" chip — a 22-episode season no longer has to be read to
  find the one row that was already known.

- **A movie's filename year now breaks TMDB's popularity ties.**
  `MetadataQuery.ranked` promotes candidates whose year matches (exactly,
  then within one, for films that straddle a new year) and is the identity
  when the filename carries no year, so a provider that ranks well is not
  second-guessed. Verified live: `/search/movie?query=Dune` returns 2021
  first, and `Dune.1984.…mkv` now surfaces Lynch's. This closes the
  "search ranking quality" item the ninth pass flagged as unverifiable
  without a key.

- **The tag diff reads in a sensible order.** `TagDiff` sorted every row
  alphabetically, so a TV episode read Director, Episode Number, Episode
  Title, Genre, Season Number, Show Name… It now follows `standardFields`'
  curated order and appends anything extra after it.

- **The movies and TV tabs get their own columns.** The table offered
  Author, Narrator, ISBN and ASIN on every tab — all four permanently
  empty for video — and no Director, Year or episode number. Added
  `Director`, `Year` and an `SxxEyy` `Episode` column, defaulted visible
  on the video tabs, with `Author` defaulted hidden there.

- **A missing TMDB key is said before the search, not after.**
  `MetadataProvider.isMissingAPIKey` (default `false`, overridden by
  `TMDBProvider`) lets the wizard show a "needs a key" state with a
  `SettingsLink` to Preferences on arrival, instead of only after a query
  the user typed was certain to fail. The error state's button changes
  from "Try Again" (which retries the same doomed search) to "Open
  Preferences…" for the same reason. The idle state's wording and icon
  also stop mentioning Audible links on a film tab.

### Coverage added

- `MatroskaTests` gained two real-media journey tests: a full movie tag set
  and a full episode tag set written to a copy of the developer's actual
  film and episode and read back, every `standardFields` key asserted, with
  the duration checked afterwards to prove the in-place patch stayed
  outside the Clusters. Both run under `OMNITAG_REAL_MEDIA` and pass.
- `LiveAPITests` gained two TMDB checks that exercise the new filename
  path end to end: a raw scene-release name finding the right show, and a
  filename year picking the right one of two same-titled films.
- `RenamePresetTests` renders and re-parses every rename preset of every
  kind — the movie and TV presets had no test at all before.

### Files split, no behaviour change

`InspectorView` moved out of `LibraryView.swift`, and the chapters and
summary steps out of `MetadataWizardView.swift` into
`MetadataWizardSteps.swift`, both because the additions above pushed the
originals past SwiftLint's type-body limit.

### Still open

- **Finalist B** (the wizard's movie-vs-TV choice writing back to a file's
  kind) is unchanged and still unbuilt — see the sixth pass above.
- **The season batch fetcher** below is likewise untouched.

## Eleventh pass: a docs audit, and the library remembers itself

A read-every-doc pass looking for what was left, wrong, or quietly broken.
Three docs made claims that were no longer true, one modelled tag key had no
way to be named in a rename pattern, and the biggest open item in `STATUS.md`
turned out to be small enough to just do.

### A real bug the docs led to

**`%tmdbid%` and `%synopsis%` silently meant the wrong tag.**
`FilenamePattern.vocabulary` had no entry for `.tmdbID` or `.synopsis`,
and `key(named:)` falls back to `TagKey.custom(name.uppercased())` for
anything it does not know. So `%tmdbid%` resolved to
`TagKey.custom("TMDBID")` — a *different* key from `.tmdbID` — and a
rename pattern using it rendered nothing for a file that plainly had a
TMDB ID, refusing the row as "No tmdbid". Parsing had the mirror problem:
it wrote to a custom tag nothing else reads. Both names added.

`FilenamePatternTests.everyStandardFieldIsNameable` now asserts that every
key in `TagKey.standardFields` has a placeholder name, for every kind, so
a future key cannot repeat this quietly. `[tmdbid-2667]` is the bracket
form Plex and Jellyfin read out of a filename, so this also makes OmniTag
able to name a library the way they expect.

### Docs that were wrong

- **`DEVELOPMENT.md` contradicted itself.** Its "Formatting" section said
  swiftformat and swiftlint were "**not** wired into the build, and there is
  no config in the repo" — while its own "Command line" section eight lines
  above documents `make lint` and `make format`, and both configs sit at the
  repo root. Rewritten, and it now also warns about the two things
  `make format` does to freshly-written code: it strips `\` line
  continuations out of multi-line raw strings (which silently changed a
  regex during the tenth pass — see that pass's formatter-regression note)
  and it moves `try`/`await`.
- **`ROADMAP.md` said mkv subtitle track metadata was "mp4 only"**, in a
  section titled "mkv subtitle track metadata", describing a feature
  `MediaTagReader.canWriteSubtitleTracks` gates to mkv alone. Inverted
  typo, fixed.
- **`STATUS.md` never mentioned `.avi`.** It listed flac and ogg/opus as
  "scanned and listed, not parsed at all" but omitted avi, which has
  exactly the same status and is the only one of the four that lands on a
  *video* tab — so it is the one a movie library actually meets. The
  inspector already handles it honestly (its "no writer yet" warning);
  only the doc was silent.

### Library persistence, built

`STATUS.md`'s largest "does not work yet" entry, and the item
`AUDIOBOOKS.md` named as next alongside mkv chapters (which shipped in the
eighth pass). It is small because the app is **not sandboxed**: plain file
URLs in `UserDefaults` reopen fine, so none of the security-scoped bookmark
machinery `DISTRIBUTION.md` describes is needed until the App Store is.

`LibraryRootStore` stores only the **roots**, never the scanned library. A
serialised item list would be a cache that is wrong more often than it is
useful — files move, get retagged by other tools, and get deleted while the
app is closed — whereas a rescan is fast and correct by construction. Three
behaviours are less obvious than the storage:

- A remembered folder that has since been **deleted or moved is dropped**
  (`existingRoots`), not re-scanned into an error on every launch forever.
- **Removing the last file forgets the roots.** Otherwise the next launch
  re-scans them and everything just removed comes straight back, which
  reads as the removal having failed.
- **A restored library lands on a tab that has files in it.** The app opens
  on Music; restoring a library of films into it showed "No music match"
  over a library that plainly had films in it — the fifth pass's "why has
  my file disappeared?" friction, back again at launch. Caught by
  screenshotting the actual running app after the persistence work, not by
  a test that was looking for it.

The store holds its defaults **suite name** rather than a `UserDefaults`
object, because `UserDefaults` is not `Sendable` and the model hands the
store across actors; resolving the suite per call is free. Strict
concurrency caught that, and the fix is the honest one rather than
`@unchecked Sendable`.

TDD throughout; `make test` green (357 → 367 tests). Verified in the real
app as well as in tests: seeded a root into the real defaults domain,
relaunched the built bundle, and confirmed by screenshot that the library
came back, landed on Movies, and showed the video columns. Not committed.
