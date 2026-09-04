# Music

The iTunes Search API, the last of the five kinds to get a provider. Before
this, the Music tab was the only one where the wizard button was disabled.

## Why iTunes Search

No key, no account, no rate limit worth managing (six rapid calls in a row all
answered 200), and Apple's own catalogue is the one a Mac tagger should reach
for first. MusicBrainz stays a fallback per `ROADMAP.md`, not a starting
choice: it needs a 1 req/s limiter and a real User-Agent, which is work to
build for a coverage gap that has not been shown to exist yet.

Verified against the live API, not from memory — see "What is actually true"
below, and `LiveAPITests`' `iTunes, live` suite (`OMNITAG_LIVE=1 make test`;
no key needed, unlike the TMDB suite).

## What is actually true about the API

1. **`/lookup?id=` returns nothing `/search` does not.** No composer, no
   copyright, no extra credits — the field sets are identical. So this is the
   only OmniTag provider with **no detail round trip**: `details(for:)`
   answers from the record built during the search. A second request would
   buy a request and no fields.
2. **`composerName` is absent from song results entirely**, so `.composer` is
   not written for music. (`MetadataRecord` writes narrators into `.composer`
   for audiobooks; that path is untouched.)
3. **Artwork is a 100 px thumbnail with the size in the URL path.**
   `.../100x100bb.jpg` → `.../1200x1200bb.jpg` resolves, verified live, so
   `ITunesArtwork.url` swaps the segment and OmniTag downloads a real cover
   rather than a thumbnail. `CoverImage` resamples on import regardless.
4. **`collectionArtistName` appears only on compilations.** A normal album
   omits it, so `albumArtist` falls back to the track's own artist —
   otherwise every non-compilation would lose its album artist.
5. **An unknown term is `{"resultCount":0,"results":[]}` with a 200**, an
   empty result rather than an error.

## A track is by an artist, never an author

`MetadataRecord.authors` is how every provider names "the people
responsible", and `tagSet` wrote it to `.author`, `.artist` **and**
`.albumArtist` at once. For music that put an audiobook field (`.author`) on
every song, and it clobbered the real album artist. `tagSet` now writes
`.author`/`.albumArtist` only for non-music kinds, and music sets its album
artist from the collection. See `ITunesClientTests.musicHasNoAuthorTag`.

The same block also wrote `tags.album = title` for every kind but movie and
TV — correct for an audiobook (players group them by album) and actively
wrong for a song, whose album is a real, different thing. `tagSet`'s tail is
now an explicit `switch` over the kind.

## One track's fields never land on a whole album

A music selection is usually a whole album, and the wizard applies one result
to everything selected. Writing the search result wholesale would stamp one
song's title and track number onto every file — the music form of exactly the
bug the TV episode picker exists to prevent.

So `MetadataWizardModel.withholdsPerTrackFields` is true when the kind is
music and more than one file is selected, and `perTrackKeys` (`.title`,
`.trackNumber`, `.trackTotal`, `.discNumber`, `.discTotal`) are **removed
from the proposed tag set**, not merely left unticked — a row the user could
tick would put the wrong title back. Album, artist, year, genre and artwork
still apply, and the summary step says which fields were withheld and why.

One file selected gets everything, per-track fields included.

**Not built: the album batch fetcher.** Pairing each selected file with its
own track (by track number or filename) would tag a whole album correctly in
one pass, but it breaks the wizard's core "one result for the whole
selection" assumption — the same reason `MOVIES_TV.md` scopes the season
batch fetcher as its own follow-up. These two are the same feature wearing
different hats and should be built together.

## The record cache

Search results carry everything, so the client keeps them in an actor keyed
by track id and `details(for:)` reads from it. That cache is **per-instance,
deliberately**: it was briefly `static`, which meant every client in the
process shared one map keyed only by track id, so two searches for the same
track resolved to whichever ran last. It surfaced as a test that passed alone
and failed in the suite; in the app it would have been one window's tags
leaking into another's. `ITunesProviderTests.cachesAreNotShared` pins it.

## Testing

`ITunesClientTests` and `ITunesProviderTests` run against a stubbed
`HTTPTransporting` with fixtures trimmed from real responses — no network.
The live suite adds four checks that need the real API: the real track's
fields, that the upscaled artwork URL actually serves an image over 10 KB,
that an unknown term is empty rather than an error, and that the developer's
own file name ("01 - Twin Peaks Theme.mp3") finds the right track. That last
one returns *Twin Peaks (Soundtrack From)*, track 1 of 11, 1990, Soundtrack —
matching the repo's own Twin Peaks fixture data.
