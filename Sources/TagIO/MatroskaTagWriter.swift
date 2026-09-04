import Foundation
import MediaCore

/// Writes Matroska tags **without rewriting the file**.
///
/// mkv files are gigabytes; a remux to change a title is not an acceptable cost.
/// Matroska is designed for this: elements can be overwritten in place, and
/// `Void` elements are padding that absorbs the difference. Three cases:
///
/// 1. The new `Tags` element fits where the old one was (plus any `Void` that
///    follows it) — overwrite, pad the slack.
/// 2. The old element is the last thing in the file — overwrite and let the file
///    grow or shrink at the end.
/// 3. It fits nowhere — append the new element at the end, turn the old one into
///    `Void`, and repair the `SeekHead` entry that pointed at it.
///
/// Every case is a seek-and-write of a few hundred bytes. The file is never
/// copied, so saving a tag on a 6 GB film costs the same as on a 6 MB one.
///
/// Clusters are never read, never moved, never touched.
public struct MatroskaTagWriter: Sendable {
    private enum ID {
        static let segment: UInt64 = 0x1853_8067
        static let tags: UInt64 = 0x1254_C367
        static let attachments: UInt64 = 0x1941_A469
        static let attachedFile: UInt64 = 0x61A7
        static let fileName: UInt64 = 0x466E
        static let fileMimeType: UInt64 = 0x4660
        static let fileData: UInt64 = 0x465C
        static let chapters: UInt64 = 0x1043_A770
        static let editionEntry: UInt64 = 0x45B9
        static let chapterAtom: UInt64 = 0xB6
        static let chapterTimeStart: UInt64 = 0x91
        static let chapterDisplay: UInt64 = 0x80
        static let chapterString: UInt64 = 0x85
        static let tracks: UInt64 = 0x1654_AE6B
        static let trackEntry: UInt64 = 0xAE
        static let trackUID: UInt64 = 0x73C5
        static let language: UInt64 = 0x22B59C
        static let languageBCP47: UInt64 = 0x22B59D
        static let trackName: UInt64 = 0x536E
        static let flagDefault: UInt64 = 0x88
        static let flagForced: UInt64 = 0x55AA
        static let flagEnabled: UInt64 = 0xB9
        static let void: UInt64 = 0xEC
        static let seekHead: UInt64 = 0x114D_9B74
        static let seek: UInt64 = 0x4DBB
        static let seekID: UInt64 = 0x53AB
        static let seekPosition: UInt64 = 0x53AC
    }

    private let backups: TagBackupStore?

    public init(backups: TagBackupStore? = nil) {
        self.backups = backups
    }

    public func write(
        _ tags: TagSet, artwork: [Artwork] = [], chapters: [Chapter]? = nil,
        subtitleTracks: [SubtitleTrack]? = nil, to url: URL
    ) async throws {
        guard ContainerFormat(pathExtension: url.pathExtension) == .mkv else {
            throw TagIOError.unsupportedContainer(url.pathExtension)
        }
        // Mapped, not loaded: planning reads a few kilobytes of header.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw TagIOError.unreadable(url, "cannot open file")
        }
        let fileLength = data.count
        let layout = try Self.layout(of: data, url: url)

        if let backups {
            try backups.record(MatroskaReader().read(url).tags, for: url)
        }

        var plan = Plan(fileLength: fileLength)
        try Self.planElement(&plan, id: ID.tags, newBytes: Self.serialiseTags(tags), layout: layout)
        // No artwork passed means "leave whatever cover is already there" —
        // only a non-empty list replaces the Attachments element.
        if !artwork.isEmpty {
            try Self.planElement(&plan, id: ID.attachments, newBytes: Self.serialiseAttachments(artwork), layout: layout)
        }
        // Unlike artwork, `nil` and `[]` are both meaningful here and distinct:
        // nil means the caller never touched chapters (leave them alone), an
        // explicit empty list means every chapter was removed in the inspector
        // and must be deleted, matching MPEG4ChapterWriter's contract.
        if let chapters {
            try Self.planElement(&plan, id: ID.chapters, newBytes: Self.serialiseChapters(chapters), layout: layout)
        }
        // Unlike Tags/Attachments/Chapters, Tracks also holds video/audio
        // entries and per-track binary blobs (CodecPrivate) that must survive
        // byte-for-byte — so the new bytes come from patching the *existing*
        // Tracks body, never from regenerating the whole element.
        if let subtitleTracks, let existingTracks = layout.tracks {
            let body = data.subdata(in: (existingTracks.offset + existingTracks.headerLength)
                ..< (existingTracks.offset + existingTracks.totalLength))
            let edits = Dictionary(uniqueKeysWithValues: subtitleTracks.map { ($0.trackUID, $0) })
            try Self.planElement(&plan, id: ID.tracks, newBytes: Self.patchTracks([UInt8](body), edits: edits), layout: layout)
        }

        if layout.segmentSizeIsKnown {
            let newSize = (plan.newLength ?? fileLength) - layout.segmentBodyStart
            guard newSize < (1 << (7 * layout.segmentSizeWidth)) - 1 else {
                throw TagIOError.writeFailed(url, "segment size no longer fits its declared width")
            }
            plan.patches.append(Patch(
                offset: layout.segmentSizeOffset,
                bytes: EBMLWriter.size(newSize, width: layout.segmentSizeWidth)
            ))
        }

        try Self.apply(plan, to: url)
    }

    /// Plans one top-level element's patch — the same three cases regardless of
    /// whether it is `Tags` or `Attachments`: fits in place, is last in the
    /// file, or must relocate. An append (no existing element, or a relocation)
    /// targets `plan.newLength ?? plan.fileLength`, so planning both Tags and
    /// Attachments into the same write appends the second past the first
    /// rather than at the same offset.
    private static func planElement(_ plan: inout Plan, id: UInt64, newBytes: [UInt8], layout: Layout) throws {
        let element = EBMLWriter.element(id, newBytes)
        let (existing, voidAfter) = layout.slot(for: id)

        if let existing {
            let region = existing.totalLength + voidAfter
            // Compared against the current end-of-file, not the original: an
            // earlier element planned into this same write may already have
            // appended past `plan.fileLength`, which would make this element
            // no longer truly last even though it was when `layout` was read.
            let isLast = existing.offset + region == (plan.newLength ?? plan.fileLength)

            if element.count <= region, let padding = Self.padding(region - element.count) {
                plan.patches.append(Patch(offset: existing.offset, bytes: element + padding))
            } else if isLast {
                plan.patches.append(Patch(offset: existing.offset, bytes: element))
                plan.newLength = existing.offset + element.count
            } else {
                try Self.planRelocation(&plan, id: id, element: element, layout: layout, existing: existing)
            }
        } else {
            let offset = plan.newLength ?? plan.fileLength
            plan.patches.append(Patch(offset: offset, bytes: element))
            plan.newLength = offset + element.count
        }
    }

    // MARK: patch plan

    struct Patch {
        var offset: Int
        var bytes: [UInt8]
    }

    /// Byte ranges to overwrite, and the file's length afterwards. Everything is
    /// a localised write: a 6 GB film is never copied to change a title.
    struct Plan {
        var fileLength: Int
        var patches: [Patch] = []
        var newLength: Int?
    }

    private static func planRelocation(
        _ plan: inout Plan, id: UInt64, element: [UInt8], layout: Layout, existing: Element
    ) throws {
        let region = existing.totalLength + layout.slot(for: id).voidAfter
        guard let blanked = EBMLWriter.void(totalLength: region) else {
            throw TagIOError.writeFailed(URL(filePath: "/"), "cannot pad a \(region)-byte region")
        }
        // Append first, blank second: if the process dies between the two, the
        // appended bytes sit outside the declared segment and are ignored, and
        // the old element is still intact and still correct. Appends past
        // whatever an earlier-planned element already staged, not the file's
        // original end, so planning Tags and Attachments relocation in the
        // same write never lands both at the same offset.
        let appendOffset = plan.newLength ?? plan.fileLength
        plan.patches.append(Patch(offset: appendOffset, bytes: element))
        plan.patches.append(Patch(offset: existing.offset, bytes: blanked))
        plan.newLength = appendOffset + element.count

        // The SeekHead now points at padding. Repair it if the field is wide
        // enough; otherwise blank the entry — a missing hint is legal, a wrong
        // one sends players to the wrong offset.
        if let field = layout.seekPositionField(for: id) {
            let position = UInt64(appendOffset - layout.segmentBodyStart)
            var bytes: [UInt8] = []
            var remaining = position
            repeat {
                bytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            } while remaining > 0

            if bytes.count <= field.bodyLength {
                plan.patches.append(Patch(
                    offset: field.offset + field.headerLength,
                    bytes: [UInt8](repeating: 0, count: field.bodyLength - bytes.count) + bytes
                ))
            } else if let blank = EBMLWriter.void(totalLength: field.totalLength) {
                plan.patches.append(Patch(offset: field.offset, bytes: blank))
            }
        }
    }

    /// Applies the plan with seek-and-write. No temp copy: staging a 6 GB file
    /// to change a title is the cost this whole design exists to avoid. The
    /// safety net is different in kind — every patch lands outside the Clusters,
    /// the previous tags are already archived, and the result is re-parsed
    /// afterwards so a broken write is reported rather than assumed fine.
    private static func apply(_ plan: Plan, to url: URL) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forUpdating: url) } catch {
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }
        defer { try? handle.close() }

        do {
            for patch in plan.patches {
                try handle.seek(toOffset: UInt64(patch.offset))
                try handle.write(contentsOf: Data(patch.bytes))
            }
            if let newLength = plan.newLength, newLength < plan.fileLength {
                try handle.truncate(atOffset: UInt64(newLength))
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }

        guard let verified = try? MatroskaReader().read(url), (verified.duration ?? 0) > 0 else {
            throw TagIOError.writeFailed(url, "file failed verification after write")
        }
    }

    // MARK: layout

    struct Element {
        var offset: Int // start of the element id
        var headerLength: Int // id + size VINT
        var bodyLength: Int
        var totalLength: Int {
            headerLength + bodyLength
        }
    }

    struct Layout {
        var segmentBodyStart: Int
        var segmentSizeOffset: Int
        var segmentSizeWidth: Int
        var segmentSizeIsKnown: Bool
        var tags: Element?
        var voidAfterTags: Int
        var attachments: Element?
        var voidAfterAttachments: Int
        var chapters: Element?
        var voidAfterChapters: Int
        var tracks: Element?
        var voidAfterTracks: Int
        var seekPositionFields: [UInt64: Element] = [:] // SeekPosition payloads, keyed by the id they point at

        func seekPositionField(for id: UInt64) -> Element? {
            seekPositionFields[id]
        }

        /// The existing element and adjacent Void for one of the four ids this
        /// writer plans — Tags, Attachments, Chapters or Tracks — so
        /// `planElement` and `planRelocation` never hardcode which is which.
        func slot(for id: UInt64) -> (existing: Element?, voidAfter: Int) {
            switch id {
            case MatroskaTagWriter.ID.tags: (tags, voidAfterTags)
            case MatroskaTagWriter.ID.attachments: (attachments, voidAfterAttachments)
            case MatroskaTagWriter.ID.chapters: (chapters, voidAfterChapters)
            default: (tracks, voidAfterTracks)
            }
        }
    }

    /// One pass over the top-level elements. Cluster bodies are skipped by size,
    /// so this costs a few reads regardless of file size.
    static func layout(of data: Data, url: URL) throws -> Layout {
        var reader = EBMLReader(data)
        guard let header = try? reader.readElementID(), header == 0x1A45_DFA3,
              let headerSize = try? reader.readSize()
        else { throw TagIOError.unreadable(url, "not a Matroska file") }
        reader.skip(Int(headerSize))

        guard let segmentID = try? reader.readElementID(), segmentID == ID.segment else {
            throw TagIOError.unreadable(url, "no Matroska segment")
        }
        let sizeOffset = reader.offset
        // `try?` flattens the optional a throwing `-> UInt64?` returns, which
        // would hide "unknown size" as a parse failure — so read it explicitly.
        let segmentSize: UInt64?
        do { segmentSize = try reader.readSize() } catch {
            throw TagIOError.unreadable(url, "unreadable segment size")
        }
        var layout = Layout(
            segmentBodyStart: reader.offset,
            segmentSizeOffset: sizeOffset,
            segmentSizeWidth: reader.offset - sizeOffset,
            segmentSizeIsKnown: segmentSize != nil,
            tags: nil, voidAfterTags: 0, attachments: nil, voidAfterAttachments: 0,
            chapters: nil, voidAfterChapters: 0, tracks: nil, voidAfterTracks: 0
        )

        let end = segmentSize.map { layout.segmentBodyStart + Int($0) } ?? data.count
        var previousElement: UInt64?

        while reader.offset < min(end, data.count) {
            let start = reader.offset
            guard let elementID = try? reader.readElementID(),
                  let size = try? reader.readSize()
            else { break }
            let element = Element(
                offset: start, headerLength: reader.offset - start,
                bodyLength: Int(size)
            )
            let bodyEnd = min(data.count, reader.offset + element.bodyLength)

            switch elementID {
            case ID.tags:
                layout.tags = element
                previousElement = ID.tags
            case ID.attachments:
                layout.attachments = element
                previousElement = ID.attachments
            case ID.chapters:
                layout.chapters = element
                previousElement = ID.chapters
            case ID.tracks:
                layout.tracks = element
                previousElement = ID.tracks
            case ID.void where previousElement == ID.tags:
                layout.voidAfterTags += element.totalLength
            case ID.void where previousElement == ID.attachments:
                layout.voidAfterAttachments += element.totalLength
            case ID.void where previousElement == ID.chapters:
                layout.voidAfterChapters += element.totalLength
            case ID.void where previousElement == ID.tracks:
                layout.voidAfterTracks += element.totalLength
            case ID.seekHead:
                layout.seekPositionFields = seekPositionFields(in: data, from: reader.offset, to: bodyEnd)
                previousElement = nil
            default:
                previousElement = nil
            }
            reader.seek(to: bodyEnd)
        }
        return layout
    }

    /// The `SeekPosition` element inside every `Seek` entry that names Tags or
    /// Attachments, keyed by which one it points at.
    private static func seekPositionFields(in data: Data, from start: Int, to end: Int) -> [UInt64: Element] {
        var reader = EBMLReader(data, offset: start)
        var fields: [UInt64: Element] = [:]
        while reader.offset < end {
            guard let id = try? reader.readElementID(), let size = try? reader.readSize() else { break }
            let entryEnd = min(end, reader.offset + Int(size))
            guard id == ID.seek else { reader.seek(to: entryEnd)
                continue
            }

            var targetID: UInt64?
            var position: Element?
            while reader.offset < entryEnd {
                let fieldStart = reader.offset
                guard let fieldID = try? reader.readElementID(),
                      let fieldSize = try? reader.readSize()
                else { break }
                let length = Int(fieldSize)
                let field = Element(
                    offset: fieldStart, headerLength: reader.offset - fieldStart, bodyLength: length
                )
                if fieldID == ID.seekID, let bytes = reader.readData(length: length) {
                    let idBytes = [UInt8](bytes)
                    if idBytes == EBMLWriter.id(ID.tags) {
                        targetID = ID.tags
                    } else if idBytes == EBMLWriter.id(ID.attachments) {
                        targetID = ID.attachments
                    } else if idBytes == EBMLWriter.id(ID.chapters) {
                        targetID = ID.chapters
                    } else if idBytes == EBMLWriter.id(ID.tracks) {
                        targetID = ID.tracks
                    }
                } else {
                    if fieldID == ID.seekPosition {
                        position = field
                    }
                    reader.skip(length)
                }
            }
            if let targetID, let position {
                fields[targetID] = position
            }
            reader.seek(to: entryEnd)
        }
        return fields
    }

    // MARK: editing

    /// Padding that fills `gap` exactly. A one-byte gap has no representation,
    /// so callers must avoid producing one.
    static func padding(_ gap: Int) -> [UInt8]? {
        gap == 0 ? [] : EBMLWriter.void(totalLength: gap)
    }

    // Rewrites the Segment's declared size in place. The width of the VINT
    // cannot change — everything after it would shift — but Matroska writers
    // use 8-byte sizes precisely so this is always possible.

    // MARK: serialising

    /// One `Tag` element per target level, each holding its `SimpleTag`s.
    static func serialiseTags(_ tags: TagSet) -> [UInt8] {
        var byLevel: [Int: [(String, String)]] = [:]
        for (key, value) in tags.values {
            guard let (name, level) = MatroskaKeyMap.writeName(for: key),
                  let text = value.stringValue, !text.isEmpty
            else { continue }
            byLevel[level, default: []].append((name, text))
        }

        var payload: [UInt8] = []
        for (level, pairs) in byLevel.sorted(by: { $0.key > $1.key }) {
            let targets = EBMLWriter.element(0x63C0, EBMLWriter.uint(0x68CA, UInt64(level)))
            let simpleTags = pairs.sorted { $0.0 < $1.0 }.flatMap { name, text in
                EBMLWriter.element(0x67C8,
                                   EBMLWriter.string(0x45A3, name)
                                       + EBMLWriter.string(0x4487, text)
                                       + EBMLWriter.string(0x447A, "und")) // TagLanguage: required by the spec
            }
            payload += EBMLWriter.element(0x7373, targets + simpleTags)
        }
        return payload
    }

    /// One `AttachedFile` per cover. `cover.jpg`/`cover.png` is the name every
    /// other mkv-writing tool (mkvpropedit, Jellyfin) uses for the file Plex
    /// and players pick up as the poster.
    static func serialiseAttachments(_ artwork: [Artwork]) -> [UInt8] {
        artwork.flatMap { art -> [UInt8] in
            let ext = art.mimeType == "image/png" ? "png" : "jpg"
            return EBMLWriter.element(ID.attachedFile,
                                      EBMLWriter.string(ID.fileName, "cover.\(ext)")
                                          + EBMLWriter.string(ID.fileMimeType, art.mimeType)
                                          + EBMLWriter.element(ID.fileData, [UInt8](art.data)))
        }
    }

    /// One `EditionEntry` holding one `ChapterAtom` per chapter — OmniTag's
    /// `Chapter` model has no concept of multiple editions, so this always
    /// writes a single default edition, same as what `MatroskaReader` flattens
    /// every edition into on read. Times are absolute nanoseconds, independent
    /// of TimestampScale, matching `readChapterAtom`'s read side.
    static func serialiseChapters(_ chapters: [Chapter]) -> [UInt8] {
        let atoms = chapters.map { chapter -> [UInt8] in
            let start = EBMLWriter.uint(ID.chapterTimeStart, UInt64(chapter.start * 1_000_000_000))
            let display = EBMLWriter.element(ID.chapterDisplay, EBMLWriter.string(ID.chapterString, chapter.title))
            return EBMLWriter.element(ID.chapterAtom, start + display)
        }
        return EBMLWriter.element(ID.editionEntry, atoms.flatMap(\.self))
    }

    /// Patches a `Tracks` element's body byte-for-byte, replacing only the six
    /// known editable fields on a matched TrackEntry (keyed by TrackUID).
    /// Every other TrackEntry — video, audio, an un-edited subtitle track —
    /// and every other field of a matched one (CodecPrivate, DefaultDuration,
    /// anything OmniTag doesn't model) is copied verbatim. An edit with no
    /// matching TrackUID in the file is silently dropped, never inserted as a
    /// phantom track: this writer edits tracks that exist, it does not mux
    /// new ones.
    static func patchTracks(_ body: [UInt8], edits: [UInt64: SubtitleTrack]) -> [UInt8] {
        guard !edits.isEmpty else { return body }
        var reader = EBMLReader(Data(body))
        var result: [UInt8] = []

        while !reader.isAtEnd {
            let entryStart = reader.offset
            guard let id = try? reader.readElementID(), let size = try? reader.readSize() else { break }
            let entryEnd = reader.offset + Int(size)
            guard id == ID.trackEntry else {
                result += body[entryStart ..< entryEnd]
                reader.seek(to: entryEnd)
                continue
            }

            if let uid = trackUID(in: body, from: reader.offset, to: entryEnd), let edit = edits[uid] {
                let patchedBody = patchTrackEntry(body, from: reader.offset, to: entryEnd, with: edit)
                result += EBMLWriter.element(ID.trackEntry, patchedBody)
            } else {
                result += body[entryStart ..< entryEnd]
            }
            reader.seek(to: entryEnd)
        }
        return result
    }

    private static func trackUID(in body: [UInt8], from start: Int, to end: Int) -> UInt64? {
        var reader = EBMLReader(Data(body), offset: start)
        while reader.offset < end {
            guard let id = try? reader.readElementID(), let size = try? reader.readSize() else { return nil }
            let fieldEnd = reader.offset + Int(size)
            if id == ID.trackUID {
                return reader.readUInt(length: Int(size))
            }
            reader.seek(to: fieldEnd)
        }
        return nil
    }

    /// Re-walks one TrackEntry's children, dropping the six fields this
    /// writer manages (they are re-added fresh from `edit` at the end) and
    /// copying every other child byte-for-byte.
    private static func patchTrackEntry(_ body: [UInt8], from start: Int, to end: Int, with edit: SubtitleTrack) -> [UInt8] {
        let managed: Set<UInt64> = [ID.language, ID.languageBCP47, ID.trackName, ID.flagDefault, ID.flagForced, ID.flagEnabled]
        var reader = EBMLReader(Data(body), offset: start)
        var kept: [UInt8] = []

        while reader.offset < end {
            let fieldStart = reader.offset
            guard let id = try? reader.readElementID(), let size = try? reader.readSize() else { break }
            let fieldEnd = reader.offset + Int(size)
            if !managed.contains(id) {
                kept += body[fieldStart ..< fieldEnd]
            }
            reader.seek(to: fieldEnd)
        }

        var fresh: [UInt8] = []
        if let language = edit.language {
            fresh += EBMLWriter.string(ID.languageBCP47, language)
        }
        if let name = edit.name {
            fresh += EBMLWriter.string(ID.trackName, name)
        }
        fresh += EBMLWriter.uint(ID.flagDefault, edit.isDefault ? 1 : 0)
        fresh += EBMLWriter.uint(ID.flagForced, edit.isForced ? 1 : 0)
        fresh += EBMLWriter.uint(ID.flagEnabled, edit.isEnabled ? 1 : 0)
        return kept + fresh
    }

    // MARK: committing

    // Same discipline as every other writer: stage, verify, swap. The staged
    // copy costs a full file write, which for gigabytes is the price of never
    // leaving a half-written film behind.
}
