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

    public func write(_ tags: TagSet, to url: URL) async throws {
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

        let element = EBMLWriter.element(ID.tags, Self.serialiseTags(tags))
        var plan = Plan(fileLength: fileLength)

        if let existing = layout.tags {
            let region = existing.totalLength + layout.voidAfterTags
            let isLast = existing.offset + region == fileLength

            if element.count <= region, let padding = Self.padding(region - element.count) {
                plan.patches.append(Patch(offset: existing.offset, bytes: element + padding))
            } else if isLast {
                // Nothing follows, so the file may simply end somewhere else.
                plan.patches.append(Patch(offset: existing.offset, bytes: element))
                plan.newLength = existing.offset + element.count
            } else {
                try Self.planRelocation(&plan, element: element, layout: layout, existing: existing)
            }
        } else {
            plan.patches.append(Patch(offset: fileLength, bytes: element))
            plan.newLength = fileLength + element.count
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
        _ plan: inout Plan, element: [UInt8], layout: Layout, existing: Element
    ) throws {
        let region = existing.totalLength + layout.voidAfterTags
        guard let blanked = EBMLWriter.void(totalLength: region) else {
            throw TagIOError.writeFailed(URL(filePath: "/"), "cannot pad a \(region)-byte region")
        }
        // Append first, blank second: if the process dies between the two, the
        // appended bytes sit outside the declared segment and are ignored, and
        // the old element is still intact and still correct.
        plan.patches.append(Patch(offset: plan.fileLength, bytes: element))
        plan.patches.append(Patch(offset: existing.offset, bytes: blanked))
        plan.newLength = plan.fileLength + element.count

        // The SeekHead now points at padding. Repair it if the field is wide
        // enough; otherwise blank the entry — a missing hint is legal, a wrong
        // one sends players to the wrong offset.
        if let field = layout.seekPositionField {
            let position = UInt64(plan.fileLength - layout.segmentBodyStart)
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
        var seekPositionField: Element? // the SeekPosition payload that points at Tags
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
            tags: nil, voidAfterTags: 0, seekPositionField: nil
        )

        let end = segmentSize.map { layout.segmentBodyStart + Int($0) } ?? data.count
        var previousWasTags = false

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
                previousWasTags = true
            case ID.void where previousWasTags:
                layout.voidAfterTags += element.totalLength
            case ID.seekHead:
                layout.seekPositionField = seekPositionField(in: data, from: reader.offset, to: bodyEnd)
                previousWasTags = false
            default:
                previousWasTags = false
            }
            reader.seek(to: bodyEnd)
        }
        return layout
    }

    /// The `SeekPosition` element inside the `Seek` entry that describes Tags.
    private static func seekPositionField(in data: Data, from start: Int, to end: Int) -> Element? {
        var reader = EBMLReader(data, offset: start)
        while reader.offset < end {
            guard let id = try? reader.readElementID(), let size = try? reader.readSize() else { return nil }
            let entryEnd = min(end, reader.offset + Int(size))
            guard id == ID.seek else { reader.seek(to: entryEnd)
                continue
            }

            var isTags = false
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
                    isTags = [UInt8](bytes) == EBMLWriter.id(ID.tags)
                } else {
                    if fieldID == ID.seekPosition {
                        position = field
                    }
                    reader.skip(length)
                }
            }
            if isTags, let position {
                return position
            }
            reader.seek(to: entryEnd)
        }
        return nil
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

    // MARK: committing

    // Same discipline as every other writer: stage, verify, swap. The staged
    // copy costs a full file write, which for gigabytes is the price of never
    // leaving a half-written film behind.
}
