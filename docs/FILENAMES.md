# Filenames

Both directions of Mp3tag's *Convert*: tags into a filename, and a filename back
into tags. One sheet, one pattern language, one type — `FilenamePattern` in
`MediaCore` renders and parses, so the two halves cannot drift.

Open it with **Library ▸ Rename from Tags…** (⌘⇧R) or the table's context menu.
It acts on the current selection.

## The pattern language

Literal text with `%field%` placeholders. `%%` is a literal percent sign, and a
lone `%` with no closing delimiter is text, not a broken field.

```
%artist% - %title%                       Angelo Badalamenti - Laura Palmer's Theme
%track% %title%                          04 Laura Palmer's Theme
%show% - S%season%E%episode% - %episodetitle%
%title% (%year%)
%author% - %series% %seriesindex% - %title%
```

Field names, as the sheet's **Field** menu lists them:

| | |
|---|---|
| Music | `title` `artist` `albumartist` `album` `genre` `year` `track` `tracktotal` `disc` `disctotal` `comment` `composer` `grouping` |
| Books and audiobooks | `author` `narrator` `series` `seriesindex` `publisher` `isbn` `asin` `language` `subtitle` |
| Video | `show` `season` `episode` `episodetitle` `director` `studio` `rating` |

Anything else — `%mood%` — is a `TagKey.custom`, the same key an unmodelled
frame round-trips through. It is not an error, and it works in both directions.

`track`, `tracktotal`, `disc`, `disctotal`, `season`, `episode` and
`seriesindex` are counting numbers: zero-padded to two digits on the way out,
matched as digits and stripped of leading zeros on the way back in. `year` is
deliberately not one of them.

Patterns name a file, never a path. A `/` or `:` in a tag value becomes `-`,
because both are path separators as far as macOS is concerned. Runs of
whitespace collapse, leading dots and trailing dots or spaces are trimmed, and
the stem is capped at 200 bytes — the filesystem's limit is 255, and the rest is
room for the extension.

## Tags to filename

The preview is the plan: `RenamePlan` renders every row and the sheet shows what
each file would become, so nothing renames on a value the user could not read
first. A row is one of six states:

| State | Meaning |
|---|---|
| Rename | It will move. |
| Already named | The file already has this name. |
| No *field* | The pattern asked for a field this file has not got. Refused, and the row says which. |
| Nothing to name it | Everything rendered empty. |
| Two files, one name | Another file in the same selection wants this name. Both are refused. |
| Name already taken | A file of that name is on disk, outside the selection. |

Only *Rename* rows move. A file missing one of the pattern's fields is refused
rather than renamed with a gap in it — the row names the field, so the fix is to
fill the tag in and come back.

The extension is preserved exactly, case included.

## Filename to tags

The same pattern becomes a parser: literals are matched literally, fields become
captures, and the whole name (minus its extension) has to match or the file is
skipped. A name that does not match reads *No match* in the preview and is left
alone — a half-filled `TagSet` written across a selection is exactly the silent
damage this app refuses.

Captured values are trimmed; a capture that comes back empty leaves the tag
unset rather than setting it to `""`. The same field twice in one pattern
becomes a back-reference, so `%artist% - %artist%` matches `A - A` and not
`A - B`.

Two adjacent fields with no literal between them (`%artist%%title%`) will match,
but the split is arbitrary. Put a separator between them.

## What happens on apply

The two directions land differently, on purpose:

- **Renames happen on disk immediately.** There is no useful "unsaved rename"
  state, and a file renamed only in memory is a file the next save writes to the
  wrong path. `EditEngine.rename` moves each file, then re-keys the working set,
  the saved baseline, the display order and both history stacks, so unsaved tag
  edits follow the file and ⌘Z moves it back. A destination that appeared since
  the preview is checked again and refused; a failure never stops the batch.
- **Parsed tags are ordinary unsaved edits.** `applyTagDeltas` writes one delta
  per file as a single undoable batch, and nothing touches the file until save.

## Where the code is

| | |
|---|---|
| `Sources/MediaCore/FilenamePattern.swift` | tokeniser, `render`, `parse`, the field vocabulary |
| `Sources/EditEngine/RenamePlan.swift` | the preview and the moves it produces |
| `Sources/EditEngine/EditEngine.swift` | `rename`, `applyTagDeltas`, URL re-keying |
| `Sources/OmniTagApp/RenameSheet.swift` | the sheet, presets, live preview |
| `Tests/MediaCoreTests/FilenamePatternTests.swift` | pattern behaviour, both directions |
| `Tests/EditEngineTests/RenameTests.swift` | planning and applying, against real files |
