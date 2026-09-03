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
   artwork shown. Three tick-presets — **Fill empty**, **Take all**, **None** —
   and a **Clean overwrite** switch that also removes the tags the provider does
   not supply. The ticked rows are what gets written.
5. Chapter diff, if the provider returned chapters and one file is selected:
   the same side by side, with every title editable before committing.
6. Write, through the existing `EditEngine` so the whole thing is one undoable
   batch.

## Chapter editing

Chapters are `[Chapter]` on `MediaItem`, and there are two places to change them.

**In the inspector**, for a single audio selection: the chapter list shows every
mark, its start time is a link that plays from there, the title is editable in
place, and `-` removes one. The transport bar's **Add Marker** drops a new
chapter at the playhead.

**In the wizard**, against a provider: the chapters step pairs the file's
chapters with the provider's and shows what will be written.

### How the two lists are reconciled

One rule, not a menu of them: **the file's timings win, the provider's titles
are borrowed**. The timings came from the audio; Audible's are a different
master and drift from the file's by a minute or more over a twelve-hour book.
A file with no chapters at all is the exception — there, the provider's
chapters are imported outright, times and all.

Matching titles onto times is nearest-wins with two guards, both learned from
real books:

- The provider list carries seconds-long "Part Two" markers that sit on top of a
  real chapter. Taking one shifts every later title by one, so a candidate whose
  length is nothing like the file chapter's is refused.
- A match more than two minutes out is not a match, and the file's own title stays.

The step starts with **Update chapters** on. It starts off in one case: the file
already has written-out titles ("Blood from misunderstanding") and the provider
only has numbered ones. Losing those to "Chapter 7" is the one outcome worth
defaulting against; a differing chapter count is not, because the timings are
kept either way.

Beyond that the table is the truth: any title can be typed over, **Bulk Tools**
retitles every row from a pattern (`Chapter %n%`, `%n%. %title%`), the up/down
arrows slide the titles a row when a list comes back one out, and **Reset** goes
back to the provider's answer.

### Writing them

`MPEG4ChapterWriter` rebuilds the file with an `AVAssetWriter`: the audio is
copied through un-decoded, a QuickTime text track is generated beside it, and the
two are associated. `AVAssetExportSession` cannot do this — and, verified against
a real m4b, a passthrough export *drops* the chapter track a file arrived with.
So every MPEG-4 file that has chapters is written this way, whether or not the
chapters were what changed. It is not the slow path it sounds like: a 234 MB,
10.7-hour audiobook is rewritten in about 1.2 seconds.

The write is staged, verified — playable, right duration, right chapter count —
and swapped atomically, like every other writer here.

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
- **The alignment rewrites the rows**, so the table previews exactly what will
  be written.
- **A pasted ASIN or Audible link is a lookup, not a search.** The field detects
  a `B…` identifier in whatever is pasted, shows an ASIN badge, and queries the
  product endpoint directly.
- **Bulk chapter tools.** Retitle all with `Chapter %n%` / `%n%. %title%`, or
  slide the titles a row when the provider's list is offset from the file's.
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
