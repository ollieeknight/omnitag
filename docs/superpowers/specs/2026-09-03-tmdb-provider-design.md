# TMDB movie/TV metadata provider — design

Status: implemented (2026-09-03). Roadmap item 1 (movies + TV half); music
(iTunes/MusicBrainz) stays a separate, later sub-item. Verified against the
real TMDB API and the developer's own Twin Peaks files. See `STATUS.md` and
`docs/MOVIES_TV.md` for the built shape; a season-batch fetcher is noted
there as a follow-up, not built.

## Why

`ROADMAP.md` names TMDB as the highest-value unbuilt provider: the only one
that needs a key, and the one covering the two kinds (movie, tvEpisode) with
no provider at all today. Audible/Audnexus (audiobook) and OpenLibrary (book)
already establish the shape; this extends it rather than inventing a new one.

## Scope

In: `TMDBClient`, `TMDBProvider`, Keychain-backed API key, a Preferences pane
to set it, a TV episode-picker wizard step, `TagKey.tmdbID`.

Out: iTunes/MusicBrainz (music — separate roadmap sub-item), IMDB IDs,
"where to watch" data (permanently out of scope, see `DECISIONS.md`),
TMDB's `/search/multi`, TVmaze (only if TMDB's episode data proves thin —
not yet).

## MetadataAPI additions

- `TMDBClient.swift` — same shape as `AudnexusClient`/`OpenLibraryClient`:
  `searchMovies(query:limit:)`, `searchTV(query:limit:)`, `movieDetails(id:)`,
  `tvShowDetails(id:)`, `episodeDetails(showID:season:episode:)`. Behind
  `HTTPTransporting` for test stubs, same as every existing client.
- `TMDBProvider: MetadataProvider`, `kinds = [.movie, .tvEpisode]`. `search`
  routes to `/search/movie` or `/search/tv` by the kind the wizard is
  running for (the wizard already scopes providers by kind — see
  `MetadataWizardModel.kind` — so this is threaded through, never guessed
  from the response). `details(for:)` on a movie candidate fetches
  immediately; on a TV candidate it returns the **show-level**
  `MetadataDetails` — no episode chosen yet, that is the new wizard step's
  job.
- `TagKey.tmdbID` — new case in `MediaCore/Tags.swift`, alongside `.asin`/
  `.isbn`. Added to `MetadataRecord.tagSet` and to `standardFields(for:)`
  for `.movie` and `.tvEpisode`. Mirrors the existing precedent: a
  provider-issued ID persisted to the file so a later "refresh metadata"
  can skip search, and third-party tools (Plex, Jellyfin) that look for a
  TMDB id tag find one.
- `MetadataError` gains a case for "no key configured" (distinct from
  `.transport`/`.server`, since the wizard should render it as "add your
  TMDB key in Preferences", not as a generic failure).

## API key storage

TMDB is the first OmniTag provider needing a secret, so this is genuinely
new ground (`AGENTS.md`'s roadmap note already commits to Keychain, never
the binary or the repo).

- `Sources/MetadataAPI/TMDBKeyStore.swift`: a direct wrapper over
  `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` /
  `SecItemDelete` — `kSecClassGenericPassword`, service `"omnitag.tmdb"`.
  No third-party Keychain library: this is ~40 lines against a system
  framework, consistent with "no third-party dependencies" in
  `DECISIONS.md`.
- A new SwiftUI `Settings` scene (`Sources/OmniTagApp/PreferencesView.swift`)
  with a secure field for the key, written to Keychain on change.
- `TMDBProvider` reads the key at construction. If absent,
  `MetadataProviders.serving(.movie)` / `.serving(.tvEpisode)` still list
  it — hiding it silently would look like a bug — but `search` throws the
  new `MetadataError` case, which the wizard's existing `.error` search
  state already knows how to render.

## Wizard changes

- `MetadataWizardModel.WizardStep` gains `.episode`, included in `steps`
  only when `kind == .tvEpisode` and the selected candidate is a TV show.
  This mirrors exactly how `.chapters` is conditionally included today
  (`steps` filters it out when `!(hasProviderChapters && canWriteChapters)`).
- New step UI, `EpisodePickerView`, added to `MetadataWizardView.swift`:
  a season selector, an episode list fetched from
  `/tv/{id}/season/{n}`, and picking one calls the provider's
  episode-resolving `details` path to produce the final `MetadataDetails`
  (title, season/episode numbers, air date, synopsis, director if TMDB
  has it).
- Everything downstream — tag diff, artwork download, apply, undo — reuses
  the existing machinery unmodified; a TV episode's `MetadataDetails` is
  just another value flowing into `TagDiff` and `buildSnapshot()`.

## Tests

`MetadataAPITests`:
- `TMDBClientTests` — stubbed transport: movie search, TV search, movie
  detail, show detail, episode detail, key-missing error, malformed
  response, non-200 status.
- `TMDBKeyStoreTests` — round-trip through a real but test-scoped Keychain
  item (unique service string per test run), deleted in teardown.
- A `TMDBProvider` case added to the existing `LiveAPITests`, gated on
  `OMNITAG_LIVE=1`, key read from an environment variable — never
  committed, never required for `make test`.

No mocks for the filesystem/Keychain beyond what `HTTPTransporting`
already stubs; the Keychain test writes and reads a real (test-scoped)
item, per `AGENTS.md`'s "no mocks" rule applied to system frameworks the
same way it applies to the filesystem.

## Docs

- New `docs/MOVIES_TV.md`, mirroring `AUDIOBOOKS.md`/`BOOKS.md`: TMDB API
  shape, key setup (where the Preferences pane is, what scopes/tier the
  free key needs), the episode-picker flow, what gets written to tags.
- `STATUS.md` and `ROADMAP.md` updated in the same commit as the code that
  makes them true, per `AGENTS.md`'s non-negotiable.
- `ARCHITECTURE.md`'s `MetadataProvider` client list and "Metadata APIs"
  section updated to include TMDB alongside Audible/Audnexus/OpenLibrary.

## Build order

1. `TagKey.tmdbID` in `MediaCore` (smallest unit, everything else depends
   on it existing).
2. `TMDBKeyStore` (Keychain wrapper) + tests — no network, no UI, can be
   verified in isolation.
3. `TMDBClient` (movie search/detail, TV search/detail, episode detail) +
   stubbed-transport tests — the bulk of the work, TDD per method.
4. `TMDBProvider` conforming to `MetadataProvider`, wired into
   `MetadataProviders.all`/`.serving(_:)`.
5. Preferences pane (Settings scene) wired to `TMDBKeyStore`.
6. Wizard `.episode` step + `EpisodePickerView`.
7. Docs (`MOVIES_TV.md`, `STATUS.md`, `ROADMAP.md`, `ARCHITECTURE.md`) in
   the same commit as whichever step makes each claim true.

Each step lands as its own TDD cycle (red, green, then move on) rather
than one large commit, per `AGENTS.md`'s TDD non-negotiable.
