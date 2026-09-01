# Book formats — design

Date: 2026-09-01. Status: approved, in implementation.

Add EPUB and PDF to OmniTag with the same treatment audiobooks have: read,
write, a library tab, an inspector field set, and provider-driven metadata
lookup.

## Why this shape

Two facts were verified before the design, not assumed:

- **PDF metadata round-trips through PDFKit**, and a metadata-only rewrite
  preserves annotations and outlines. Probed against a generated PDF carrying
  both.
- **EPUB needs no dependency.** A real EPUB's central directory was walked and
  its OPF inflated with Foundation plus `Compression` alone. This keeps the
  no-third-party-dependencies decision intact.

## Module layout

Backends live in `TagIO` beside the Matroska ones, because `MediaTagReader` and
`MediaTagWriter` are the single façade and must keep routing in one place — the
same way mkv was added.

```
MediaCore    MediaKind.book · ContainerFormat.epub/.pdf · TagKey.language
TagIO        ZipArchive · OPFDocument · EPUBKeyMap · EPUBReader · EPUBTagWriter
             PDFReader · PDFTagWriter · façade routing
MetadataAPI  protocol MetadataProvider · Audible and OpenLibrary behind it
OmniTagApp   Books tab · book field set · provider-driven wizard
```

## EPUB

**Read.** End-of-central-directory → central directory → inflate
`META-INF/container.xml` → OPF path → inflate the OPF → parse `<metadata>`.

Parsing is **namespace-aware, not prefix-matching**. The developer's real copy
of *The Secret Diary of Laura Palmer* declares `<description>` in a default
Dublin Core namespace rather than with a `dc:` prefix; a prefix matcher silently
loses the summary.

Cover art comes from the manifest item with `properties="cover-image"` (EPUB 3)
or, failing that, `<meta name="cover" content="…">` naming a manifest id
(EPUB 2 — what the real file uses).

Series reads EPUB 3 `belongs-to-collection` refinements, falling back to
`calibre:series`, because that is what actual libraries contain.

**Write.** Regenerating the OPF would breach the lossless round-trip invariant,
so the metadata block is edited **surgically**: bytes outside `<metadata>` are
never touched, and elements we do not model become `TagKey.custom`.

Rebuilding the archive copies every untouched entry's **already-compressed bytes
verbatim** — no re-deflate, so the rest of the book is byte-identical and the
write is fast. Only the OPF is re-deflated. `mimetype` stays the first entry,
stored, with no extra field, as EPUB requires.

Then the house discipline: `TagBackupStore` first, stage to a sibling temp,
re-read to prove it parses, atomic `replaceItemAt`.

## PDF

`PDFDocument.documentAttributes` both directions. Encrypted, locked, or
digitally-signed files are refused with a reason rather than re-serialised —
the same call the ID3 writer makes on v2.2 tags.

No artwork writing: a PDF has no cover atom. The inspector shows page one as a
preview and disables the well.

## Provider generalisation

`Audiobook{Query,Candidate,Details}` become neutral `Metadata*` types behind the
`MetadataProvider` protocol `ARCHITECTURE.md` already specifies. `AudibleProvider`
wraps the existing service; `OpenLibraryProvider` finishes the stub, which
currently smuggles a `/works/` key through the `asin` field and gets a
provider-scoped id instead. The wizard offers providers whose `kinds` contain the
current tab. `Details.chapters` carries the EPUB table of contents, read-only.

## Testing

Fixtures are generated, never committed. The load-bearing test: archives written
by `ZipArchive` must open with **`/usr/bin/unzip`**, not merely with our own
reader. Real-file assertions against the Twin Peaks EPUB run under
`OMNITAG_REAL_MEDIA`, and must never write to the original.

## Risks

The zip **writer** is the one new hazard. Contained by system-unzip
verification, staged writes, and backups. The provider rename touches 161
passing tests and runs as its own mechanical step, green either side.

## Sequence

1. `ZipArchive` + EPUB read + Books tab (read-only)
2. EPUB write
3. PDF read and write
4. Provider protocol + OpenLibrary in the wizard
5. Books polish — columns, fields, cover well
