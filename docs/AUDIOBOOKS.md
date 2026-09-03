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
  a rename pattern (`Chapter %n%`, `%title%`), and a "keep my titles, take their
  times" toggle.
- **Writing m4b chapters** is the hard part. AVFoundation cannot patch a chapter
  track in place; it writes chapters by building a new text track, which means
  `AVAssetWriter` and a full remux of a several-hundred-megabyte file. Options:
  1. Remux via `AVAssetWriter`, showing progress. Correct, slow, safe.
  2. Patch the `moov/udta/chpl` (Nero) atom in place, like the mkv writer does.
     Fast, but only some players read `chpl`, and the QuickTime chapter track
     would still disagree with it.
  3. Do both: patch `chpl` and rewrite the text track's sample data in place
     when the new titles fit the existing sample sizes.
  **Decision**: (1) is now implemented via `MPEG4ChapterWriter`, because correctness beats speed for a feature
  that runs once per book. (2) may be added later as a fast path when only titles
  changed and the file already has a `chpl` atom.

Whatever is chosen, the write goes through the same staged-and-verified
discipline as every other writer, and the previous chapters are archived
alongside the previous tags.

## The library around it

The audiobook tab is where the wizard is reached from, so it carries the fields
the wizard writes: sortable Narrator, Series and ASIN columns (hidden by default
in the other tabs, and hideable by right-clicking the header), a cover thumbnail,
and an orange dot on any file whose edits are not yet on disk. ⌘L opens the
wizard on the selection; ⌘R reveals it in the Finder.

### Audio player and playback

A docked mini-transport bar appears whenever an audio file is selected. Built on
`AVPlayer`, it provides instant playback of `.m4b`, `.m4a`, `.mp3`, `.wav`,
`.aiff`, and `.flac`. Features:
- Spacebar toggle for Play/Pause.
- Continuous scrub slider with 100ms periodic time updates.
- 15-second jump backward (`⌘←`) and forward (`⌘→`).
- "Add Marker" / "Add at Playhead" button to insert a chapter mark at the current
  audio timestamp.

### Chapter editing in the main UI

In addition to the Metadata Wizard's side-by-side reconciliation, the Inspector
contains a live Chapter Studio for single audio selections:
- Editable title text fields.
- Clickable timecodes that seek the player directly to chapter boundaries.
- Individual chapter deletion (`-`).
- "Add at Playhead" (`+`) button.

### Artwork handling

- **Full original resolution preserved**: Cover images are preserved at their
  original resolution and byte size by default.
- **Local discovery**: "Find in Folder" scans the media item's directory for
  `cover.jpg`, `folder.jpg`, `cover.png`, or same-stem images.
- **Clipboard paste**: Paste image directly with `⌘V` or the inspector menu.
- **Drag and drop**: Drop an image directly onto the artwork well.

### Media kind triage

Files are automatically classified by extension on import (`.m4b` lands in
Audiobooks, `.epub`/`.pdf` in Books, `SxxExx` in TV Shows). If an item is
misclassified, you can reassign it by:
- Dragging and dropping rows onto sidebar tabs.
- Right-clicking rows → **Set Kind** → select destination kind.
- Changing the **Kind** picker in the inspector.

## What the wizard actually does

Four steps, and the chapters one disappears when there is nothing to reconcile
(no provider chapters, or more than one file selected).

- **Tags are written as a delta.** Only the ticked rows go to `EditEngine`,
  merged into each file's own tags.
- **The three spec'd actions are tick-presets**, not separate commit paths:
  *Fill empty* ticks only the fields the file lacks, *Take all* ticks everything
  Audible answered, *None* clears the ticks. The row is always the truth.
- **The chapter strategy rewrites the rows**, so the table previews exactly what
  will be written.
- **A pasted ASIN or Audible link is a lookup, not a search.** The field detects
  a `B…` identifier in whatever is pasted, shows an ASIN badge, and queries the
  product endpoint directly.
- **Bulk chapter tools.** Retitle all with `Chapter %n%` / `%n%. %title%`.
- **Artwork failure is not tag failure.** A cover that will not download is
  reported in the bar; the tags the user just reviewed are still applied.

## Status

Done: `MetadataAPI` module — `AudibleClient`, `AudnexusClient`,
`AudiobookMetadataService`, region fallback, search ladder, ranking, ASIN/URL
parsing, offline fixtures, live opt-in tests. **MPEG-4 chapter writing** via
`MPEG4ChapterWriter`. **The wizard UI**: search, tag diff, chapter diff, and
summary. **Audio playback**: native `AVPlayer` transport bar. **In-place chapter
editing**: full inspector studio. **Kind triage**: drag-and-drop and context menu
reassignment.

Next: mkv chapter editing and library persistence between launches.
