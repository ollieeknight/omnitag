# The main window

Three panes: scope sidebar │ file table │ inspector. This file records why the
window is shaped the way it is; `STATUS.md` records what works.

## `LibraryScope`, not a sixth `MediaKind`

The sidebar selects a `LibraryScope` — `.all` or `.kind(MediaKind)`. Making
"All" a sixth `MediaKind` case was rejected: a file is never *of* kind "all",
so the case would have leaked into `detectKind`, both key maps, `TagDiff`,
`standardFields` and every other switch over `MediaKind` in the app, each of
which would have needed a meaningless branch.

`LibraryModel.kind` — what the inspector's field set, the wizard's provider
list and the rename presets are all keyed to — is therefore **derived, never
stored**:

- Under a kind scope it is that kind.
- Under `All` a file still has exactly one kind, so the selection answers it.
- A selection whose kinds disagree falls back to `.music`, whose field set
  (title/artist/album) is the one every kind shares.

`selectedKind` is the same question without the fallback: `nil` when the
selection disagrees. The inspector's Kind picker needs that distinction —
showing one file's kind for a mixed selection makes every other file look
misfiled, and choosing from it would silently rewrite them all. It shows
"Multiple" instead.

## Per-scope columns

`All` and a kind tab are asking different questions, so they get different
columns rather than one compromise set:

- **All** shows **Kind** (a tinted glyph plus the singular noun — "Episode",
  not "TV Shows", because a row names one file and the sidebar names a
  collection) and **By**, one column carrying whichever of director / show /
  artist / author that file actually has. Album, Series, Chapters, ISBN and
  ASIN are hidden: they are per-kind vocabulary and read as noise in a mixed
  list.
- **A kind tab** keeps its own vocabulary and hides Kind and By, which the
  sidebar has already answered.

Every column is still user-customisable; these are `defaultVisibility`, not
locks.

## What the window chrome says

- **Title** is the scope; **subtitle** carries counts, save progress, unsaved
  and failed totals. The window previously used `.hiddenTitleBar`, so both
  were computed and never shown, leaving unlabelled toolbar icons as the only
  indication of where you were.
- **The status bar is gone.** Counts and progress moved to the subtitle, the
  save action to the sidebar footer where it has room for a label, and only
  *failures* still get a bar — they name a file and a reason, which no
  subtitle can carry.
- **The sidebar footer** shows save state alone. It briefly showed a file
  count too, which disagreed with the subtitle's count whenever a filter was
  on: the same number in two places is a bug waiting to happen.

`.toolbarRole(.editor)` puts the title inline beside the toolbar. It does
*not* add labels under toolbar icons on macOS 26's Liquid Glass toolbar, so
every toolbar button carries a `.help` tooltip naming it and its shortcut,
and the glyphs stay conventional (`wand.and.stars` for metadata lookup,
`square.and.pencil` for rename) rather than clever.

## Three empty states, three different answers

An empty list means one of three things, and the same panel for all three was
misleading:

| Situation | What it says |
|---|---|
| Nothing in the library | "No Media" + Add Folder / Add Files |
| Nothing of *this* kind | "No Movies" + how many files are filed elsewhere, and Show All |
| Nothing matches the filter | "No Matches" + Clear Search / Show All Files |

The second one matters most: it is the "why has my file disappeared?" friction
that `MOVIES_TV.md`'s fifth pass first documented.

## Ghost rows

The table showed a stripe for every row it *could* hold, so one file sat above
a dozen empty rows. That is `Table`'s default
`.inset(alternatesRowBackgrounds: true)`; turning it off makes the table end
where its content does, as every Mac table does.
