# What the other tools do

A 2024–2026 survey of Mp3tag, Picard, beets, Yate, Meta, Tag Editor 2, Kid3,
MediaMonkey, TagScanner, foobar2000, calibre, tinyMediaManager, FileBot and
MetaX, reconciled against an audit of what OmniTag's own code actually
exposes. This file records the **conclusions and the gaps**, not the survey;
it exists so the roadmap's ordering has a stated reason behind it.

Re-run the survey when it goes stale — the category's centre of gravity moved
between 2020 and 2026, and it will move again.

## The one lesson

The category's value is not "can edit tags". Every tool here can. It is
**can finish a 5,000-file clean-up without losing work**.

Recent evidence — Mp3tag's 2026 Mac threads, Picard 3's alpha notes, beets'
help traffic, MediaMonkey's complaint pattern — converges on the same five
needs: batch automation the user authors, filtering down to the exceptions,
duplicate handling, resumable long jobs, and artwork throughput. Feature
count is not what people are asking for; **less handwork, fewer reruns,
better previews, fewer edge-case losses** is.

## Where OmniTag is already unusual

Worth stating, because it is easy to lose sight of while cataloguing gaps:

- **Reversible on-disk undo.** One ⌘Z undoes an edit across 200 files *after*
  it was written. No tool in this survey does this.
- **Mixed media in one app.** Music, audiobooks, ebooks, movies and TV.
  Everyone else covers music, or video, or books.
- **mkv chapter and subtitle-track editing**, in-place, without rewriting a
  6 GB film. MetaX does chapters for MP4; nobody else does mkv this way.
- **A stated lossless round-trip invariant.** Unknown atoms and frames come
  back. Mp3tag was still fixing MP4-atom preservation in 2026.
- **Writes are staged, verified and swapped**, with the previous tags
  archived — against a category whose 2026 threads still feature "cannot
  write tags" and file damage on error.

The gaps below are throughput gaps, not safety gaps. That is the right way
round, and the strategy should be to keep it that way.

## The gaps, ranked

Ranked by value-to-effort **after auditing the code**, which changed several
estimates: three of these are UI-only because the engine already does the
work.

### 1. Find & Replace across a selection — *engine done, no UI*

`TagEdit.replace(key:find:with:)` exists in `EditEngine`, has a passing test,
and **cannot be reached from anywhere in the app**. Mp3tag's most-used
action; Meta markets regex find/replace on its store page. This is a sheet.

### 2. Saved actions / recipes — *the category's centre of gravity*

Ordered, reusable, user-authored edit chains: Mp3tag's Action Groups, Yate's
Actions, Meta's derive/compose. This is what people choose those tools *for*,
and it is what OmniTag most conspicuously lacks. `TagEdit` is already the
right primitive — an action is a list of `TagEdit`s plus a saved name.

Design lesson from the survey: copy **Mp3tag/Meta accessibility, not Picard
power**. Picard's script language is more capable and generates a
correspondingly large share of its support traffic. Saved ordered recipes
with a dry-run preview and a per-step diff beat an expression language for
everyone except the top 1% of users.

### 3. Bulk text transforms — *the actions people actually run*

Title Case / UPPER / lower, trim whitespace, swap two fields, copy field to
field, auto-number tracks. Pure `MediaCore` string work. These are the
individual steps a recipe is built from, so they come before recipes.

### 4. Filters and saved searches — *fresh demand everywhere*

OmniTag's search is a flat substring match over eight hardcoded fields, plus
one "unsaved only" toggle. The category has moved past this: Picard 3 is
adding pane filtering, Meta ships a filter syntax, MediaMonkey's audit views
are why people tolerate its UI.

The high-value form is **audit views**: "missing artwork", "no year",
"missing track number", "not yet saved". Tagging is exception-driven — you
want the twelve broken files out of five thousand, not a full-text search.

### 5. Multi-artwork — *cheaper than it looks*

`Artwork.Role` already has `cover`, `poster` and `backdrop`; both the MPEG-4
and Matroska writers already take and loop an **array**. The only thing
capping a file to one cover is `InspectorView` taking `.first`. Mp3tag added
a full cover manager in 2026 (add/remove/replace/reorder); Yate and Meta both
do artwork batching.

### 6. CSV import/export — *round-trip, not reporting*

Meta, Kid3, Tag Editor 2 and TagScanner all ship it. The valued workflow is
export → edit in a spreadsheet → import back, not producing a report. It is
also the cheapest possible backup of an entire library's tags.

### 7. Duplicate detection — *constant pain elsewhere*

beets' importer prompts (skip/keep/remove/merge) and MediaMonkey's Duplicate
Content view are heavily used and heavily complained about. Nothing in
OmniTag finds the same track twice.

### 8. Resumable batch queue — *the fix for everyone else's worst bug*

MediaMonkey's 2024–2026 complaints are dominated by: auto-tag capped at 100
files, hangs every few hundred, **no resume**, settings lost after a hang.
beets' importer answers exactly this with a logfile and resume-after-abort.
OmniTag's tag reading is still serial (`ponytail:`-marked in `App.swift`),
which is the same problem waiting to happen at thousands of files.

## Ruled out, with reasons

**Acoustic fingerprinting (AcoustID/Chromaprint).** High value for a badly
tagged music library, and Picard's and Tag Editor 2's real differentiator.
Deferred, not planned: Chromaprint is a C library with no Swift port, so it
would be the first dependency this project takes and the first breach of
`DECISIONS.md`'s zero-dependency rule. That is an architectural decision, not
a backlog item — see `DECISIONS.md`.

**Movie/TV sidecars** (NFO files, artwork sets, Plex/Jellyfin folder
presets). tinyMediaManager's whole reason to exist, and out of scope here:
OmniTag writes tags *into* files, whereas sidecar generation is media-server
curation, which implies owning the library's folder layout — adjacent to the
"library server" `DECISIONS.md` already rules out. See `DECISIONS.md`.

**Plugin architecture.** Picard's plugin registry is real leverage and real
support burden. A solo project with zero dependencies should not ship an
extension API before it has the built-in features people want.

## What reviewers would call out in a 1.0

In rough order of how loudly: no actions/recipes, no audit views or saved
filters, no duplicate workflow, no CSV round-trip, one cover per file.

Everything on that list is in the ranking above.
