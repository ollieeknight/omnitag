# Audiobooks

The audiobook tab is the deepest of the four, because Audible metadata is
richer than anything the other media types get and because chapters matter.

## The APIs, and what is actually true about them

Two services, because neither does the whole job:

| Need | Service | Notes |
|---|---|---|
| Search | `api.audible.<tld>/1.0/catalog/products` | Unauthenticated. One catalogue per storefront. |
| Book by ASIN | `api.audible.<tld>/1.0/catalog/products/<asin>` | Works for books search cannot find. |
| Book detail (normalised) | `api.audnex.us/books/<asin>?region=` | Clean shape, high-resolution cover URL, genres. |
| Chapters | `api.audnex.us/books/<asin>/chapters` | The only unauthenticated chapter source. |

The Mp3tag community thread (`community.mp3tag.de/t/ws-audible-via-api/64347`)
was worth reading but publishes no endpoints — it confirms the regional domain
list and a field mapping, nothing more. Everything below was verified against
the live APIs instead, and the assertions live in `LiveAPITests`
(`OMNITAG_LIVE=1 make test`).

### Four things that are not obvious

1. **Only `keywords` works.** `title=` returns zero results. `author=` returns
   unrelated books. Combining `title=` and `author=` returns zero. So the search
   runs on the title alone and the author is used to **rank** what comes back.
2. **Adding the author to the keywords destroys the search.**
   `keywords=secret diary of laura palmer` → 3 results;
   `keywords=secret diary of laura palmer jennifer lynch` → 0. Hence the
   `searchLadder`: narrow rung first, broader rung only if it found nothing.
3. **Storefronts are not mirrors.** *The Secret Diary of Laura Palmer* does not
   exist in the UK catalogue at all. The chosen region is tried first, the US
   second, and the result reports which storefront answered.
4. **The search index has holes.** That same book is invisible to every keyword
   phrasing tried, yet `catalog/products/B01M11U23O` returns it in full. This is
   why a pasted ASIN or Audible URL is a first-class query, not a power-user
   afterthought — and why a file that already carries an ASIN (the developer's
   does, in a `CDEK` atom) should search by it automatically.

### Regions

`AudibleRegion` covers uk, us, ca, au, de, fr, es, it, jp. Default is **UK**;
the US is always tried as a fallback. Audnexus takes the same region as a query
parameter and is retried the same way.

## Flow

The wizard, per the specified design:

1. Drag files into the window, or right-click a selection → **Search Metadata…**
2. Provider drop-down (default Audible UK) plus a query built from the file:
   ASIN if it has one, otherwise title/author, otherwise the cleaned filename.
   A pasted ASIN or Audible URL is accepted here too.
3. Results list — title, author, narrator, year, runtime, cover thumbnail.
4. Tag diff: current value beside proposed value, per field, with the new
   artwork shown. Three actions: **Merge** (fill only what is empty),
   **Overwrite selected** (the ticked rows), **Overwrite all** (replace the tag
   set entirely, dropping anything the provider does not supply).
5. Chapter diff, if the provider returned chapters: same side-by-side, with
   per-chapter titles editable in place before committing.
6. Write, through the existing `EditEngine` so the whole thing is one undoable
   batch.

## Chapter editing

Reading chapters is done (m4b via chapter groups, mkv via `ChapterAtom`).
Editing them is the open design question; the plan:

- **Model**: chapters are already `[Chapter]` on `MediaItem`. The diff pairs
  provider chapters with existing ones by index, and each row can take either
  side or a hand-typed title. Times come from the provider or stay as they are —
  retiming audio is not something a tagger should guess at.
- **Bulk tools** worth having, because 85-chapter audiobooks are normal:
  a rename pattern (`Chapter %n%`, `%title%`), a "keep my titles, take their
  times" toggle, and shift-all-times for an offset intro.
- **Writing m4b chapters** is the hard part. AVFoundation cannot patch a chapter
  track in place; it writes chapters by building a new text track, which means
  `AVAssetWriter` and a full remux of a several-hundred-megabyte file. Options:
  1. Remux via `AVAssetWriter`, showing progress. Correct, slow, safe.
  2. Patch the `moov/udta/chpl` (Nero) atom in place, like the mkv writer does.
     Fast, but only some players read `chpl`, and the QuickTime chapter track
     would still disagree with it.
  3. Do both: patch `chpl` and rewrite the text track's sample data in place
     when the new titles fit the existing sample sizes.
  **Recommendation: (1) first**, because correctness beats speed for a feature
  that runs once per book, with (2) added later as a fast path when only titles
  changed and the file already has a `chpl` atom.

Whatever is chosen, the write goes through the same staged-and-verified
discipline as every other writer, and the previous chapters are archived
alongside the previous tags.

## Status

Done: `MetadataAPI` module — `AudibleClient`, `AudnexusClient`,
`AudiobookMetadataService`, region fallback, search ladder, ranking, ASIN/URL
parsing, offline fixtures, live opt-in tests.

Next: the tag diff model, artwork download and `covr` writing, the wizard UI,
then chapter editing.
