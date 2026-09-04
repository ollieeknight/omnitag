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

Both items this section once named as next — mkv chapter editing and library
persistence between launches — are done; see `MOVIES_TV.md` and `STATUS.md`.


## Chapter titles: what the heuristics get wrong, and why

Measured against a real 50-book library (Horus Heresy, ffmpeg-merged from
parts, chapter titles in every state from `Chapter 1` to fully written out).

### There is no richer source to fetch

Checked before changing anything: Audnexus **does** publish chapter data for
these books, and its timings match the files exactly. But its titles are
`Opening Credits`, `Part One`, `One`, `Two`, `Three` — no richer than the
files' own `Chapter 1, Chapter 2`. Occasionally a part carries a real name
(`Part Two: Plague Moon`).

That is not a gap in the API. **The audiobooks genuinely do not have rich
chapter titles** — the publisher numbered them. So for the 23 books whose
titles are all generic, the generic titles are *correct*, and there is
nothing to fetch. Books that do have real titles got them from whoever built
the file, which is data no provider can reconstruct — and precisely why
protecting them matters more than replacing them.

Two things Audnexus has that OmniTag does not yet use: structural markers
(`Opening Credits`, `End Credits`) and `brandIntroDurationMs`, which says
where publisher branding ends.

### The ratio was backwards

`hasRichTitles` required 20% of titles to be non-generic. Three real titles
among twenty-eight generic ones scored 11% and were **silently overwritten**
— yet those three are exactly the ones that cannot be recovered. A mostly
numbered book is *more* fragile than a fully written-out one, not less.

Nine of fifty books were mis-classified this way, including *Fear to Tread*
(`Melchior`, `Ullanor`, `Nikaea`), *Fulgrim* (`Part I`–`Part V`) and *The
Master of Mankind* (`Harvest`, `Cargo`, `Choir`).

Now: **any** non-generic title protects the list, and the notice names the
titles at risk rather than only saying some exist — with three real titles in
a twenty-four-row table, "this file has written-out titles" does not tell you
which three to look at.

### `Part I` is not `Part 1`

`part` and `book` are in `genericWords`, so `Part I` and `Book II` were
judged generic. In several books those are the *only* structural markers the
file has. A Roman numeral after a structural word now reads as real; a plain
digit (`Part 4`) still reads as generic, because that is reconstructible.

## When the chapter counts do not match

`ChapterDiff.matchTitles` pairs by **timestamp, not index**: nearest provider
chapter within 120 s, requiring the two durations to be within 2× of each
other, never reusing a provider chapter. The file's timings always win, and
only titles move. On a 21-vs-25 mismatch the four extra provider chapters are
dropped rather than shifting everything by four.

The notice now reports what the alignment actually achieved — "21 matched by
timestamp, 3 chapters kept their current title" — rather than promising a
match it may not have made.

## Are the chapter boundaries even correct?

A question no provider can answer — nobody publishes where a *particular
rip's* chapters should fall. The audio is the only witness, but it has to be
read carefully, because **there is more than one correct shape**. Two books
from the developer's library, both correct, look completely different:

```
Horus Rising          A Thousand Sons
  prose                 prose
  [silence 4.5s]        [pause 2.5s]
  ▸ mark (2s in)        ▸ mark — on a spoken "Chapter Two"
  next chapter          [pause 2.0s]
                        next chapter
```

A Thousand Sons puts its marks **on the announcement**, deliberately, so that
skipping plays "Chapter Two" and then the text. A silence-only checker calls
every one of those wrong — which is worse than no checker, because it teaches
the user to ignore it.

So `ChapterBoundaryCheck` (`TagIO`) **reports the shape and does not pass
judgement**. For each mark it says how long the previous audio had already
stopped and how soon sound resumes, and produces a plain sentence:

| Real output | Meaning |
|---|---|
| `On audio, 2.8s after a pause — likely a chapter announcement.` | A Thousand Sons: correct |
| `In a pause, 2.0s after the previous audio ended.` | Horus Rising: 2 s of dead air on every skip |
| `Mid-sentence. Nearest pause +2.0s.` | The one unambiguous fault |

Only `isMidSentence` is a claim — audio at the mark with no pause either side,
so the mark cuts a sentence in half. Everything else is description.

### What the measurements had to survive

- **Threshold.** Silence measures 0.0000–0.0005, speech 0.05–0.19. Two orders
  of magnitude apart, so 0.002 is not a fine judgement.
- **Window width.** A one-second RMS window straddles the moment sound
  resumes, so it averaged in the following speech and called *every* boundary
  of a correctly cut book mid-sentence. A quarter-second measures the mark
  itself.
- **Search width.** ±60 s always finds *a* silence — every paragraph break is
  one — and produced suggestions of −57 s and +34 s in the same book. ±10 s
  matches the real error.
- **Walking past the mark's own audio.** The pause that matters is the one
  *before* a chapter announcement, so the backward scan skips up to 2.5 s of
  sound before measuring. Without this, every announcement read as
  mid-sentence.

No dependency: `AVAssetReader` decodes and the rest is a root-mean-square.
Fingerprinting is not needed to ask "is this quiet". The check is advisory —
an unreadable file returns no results rather than throwing, and nothing about
it blocks editing chapters by hand.

### Measured against the real library

Ground truths (confirmed correct by the developer): **A Thousand Sons** — 31
boundaries, 0 faults, announcement structure correctly identified.
**Horus Rising** — 21 boundaries, 0 faults, every one reported as sitting
~2 s into the pause, which is the bleed-through the developer had noticed by
ear. **Deathfire** — 67 boundaries, same 2 s pattern.
