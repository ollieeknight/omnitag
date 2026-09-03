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
