import Foundation
import MediaCore

/// Matroska (mkv) reader. AVFoundation cannot open Matroska at all, so this is
/// the only way OmniTag sees inside the container most video libraries use.
///
/// Read-only, and deliberately shallow: it walks the Segment's children, reads
/// `Info`, `Tags`, `Chapters` and cover attachments, and *skips* everything
/// else by size — Clusters hold the actual video and are never touched. The
/// file is memory-mapped, so a 7 GB film costs a few pages, not 7 GB of RAM.
public struct MatroskaReader: Sendable {
    public init() {}

    private enum ID {
        static let ebmlHeader: UInt64 = 0x1A45DFA3
        static let segment: UInt64 = 0x18538067
        static let info: UInt64 = 0x1549A966
        static let timestampScale: UInt64 = 0x2AD7B1
        static let duration: UInt64 = 0x4489
        static let title: UInt64 = 0x7BA9
        static let chapters: UInt64 = 0x1043A770
        static let editionEntry: UInt64 = 0x45B9
        static let chapterAtom: UInt64 = 0xB6
        static let chapterTimeStart: UInt64 = 0x91
        static let chapterDisplay: UInt64 = 0x80
        static let chapterString: UInt64 = 0x85
        static let tags: UInt64 = 0x1254C367
        static let tag: UInt64 = 0x7373
        static let targets: UInt64 = 0x63C0
        static let targetTypeValue: UInt64 = 0x68CA
        static let tagTrackUID: UInt64 = 0x63C5
        static let simpleTag: UInt64 = 0x67C8
        static let tagName: UInt64 = 0x45A3
        static let tagString: UInt64 = 0x4487
        static let attachments: UInt64 = 0x1941A469
        static let attachedFile: UInt64 = 0x61A7
        static let fileMimeType: UInt64 = 0x4660
        static let fileData: UInt64 = 0x465C
    }

    public func read(_ url: URL) throws -> MediaItem {
        guard let container = ContainerFormat(pathExtension: url.pathExtension) else {
            throw TagIOError.unsupportedContainer(url.pathExtension)
        }
        // Mapped, not loaded: the parser touches a few kilobytes of a huge file.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw TagIOError.unreadable(url, "cannot open file")
        }

        var reader = EBMLReader(data)
        guard let header = try? reader.readElementID(), header == ID.ebmlHeader else {
            throw TagIOError.unreadable(url, "not a Matroska file")
        }
        guard let headerSize = try? reader.readSize() else {
            throw TagIOError.unreadable(url, "unreadable EBML header")
        }
        reader.skip(Int(headerSize ?? 0))

        guard let segmentID = try? reader.readElementID(), segmentID == ID.segment,
              (try? reader.readSize()) != nil
        else { throw TagIOError.unreadable(url, "no Matroska segment") }

        var state = ParseState()
        // A segment's declared size can be unknown (live muxing); trusting the
        // file's end is correct in both cases.
        try walk(&reader, until: data.count, into: &state)

        var tags = state.tags
        // The Segment title is a fallback: a real TITLE tag always wins.
        if tags.title == nil { tags.title = state.segmentTitle }

        return MediaItem(
            url: url, kind: container.defaultKind, container: container,
            duration: state.duration, tags: tags,
            chapters: state.chapters.sorted { $0.start < $1.start }
                .enumerated().map { index, chapter in
                    var renumbered = chapter
                    renumbered.index = index
                    if renumbered.title.isEmpty { renumbered.title = "Chapter \(index + 1)" }
                    return renumbered
                },
            artwork: state.artwork)
    }

    private struct ParseState {
        var tags = TagSet()
        var chapters: [Chapter] = []
        var artwork: [Artwork] = []
        var duration: TimeInterval?
        var segmentTitle: String?
        var timestampScale: Double = 1_000_000  // nanoseconds per tick, Matroska's default
        var rawDuration: Double?
    }

    /// Walks sibling elements from the cursor to `end`, recursing only into the
    /// four branches that carry metadata.
    private func walk(_ reader: inout EBMLReader, until end: Int, into state: inout ParseState) throws {
        while reader.offset < end, !reader.isAtEnd {
            guard let elementID = try? reader.readElementID(),
                  let sizeValue = try? reader.readSize()
            else { return }
            let size = Int(sizeValue ?? UInt64(max(0, end - reader.offset)))
            let bodyEnd = min(end, reader.offset + size)

            switch elementID {
            case ID.info:
                try readInfo(&reader, until: bodyEnd, into: &state)
            case ID.chapters, ID.editionEntry:
                try walkChapters(&reader, until: bodyEnd, into: &state)
            case ID.tags:
                try walkTags(&reader, until: bodyEnd, into: &state)
            case ID.attachments, ID.attachedFile:
                try walkAttachments(&reader, until: bodyEnd, into: &state)
            default:
                reader.seek(to: bodyEnd)  // Clusters, Tracks, Cues, SeekHead: skipped whole
            }
            reader.seek(to: bodyEnd)
        }

        if let raw = state.rawDuration {
            state.duration = raw * state.timestampScale / 1_000_000_000
        }
    }

    private func readInfo(_ reader: inout EBMLReader, until end: Int, into state: inout ParseState) throws {
        while reader.offset < end {
            guard let elementID = try? reader.readElementID(),
                  let size = try? reader.readSize().map({ Int($0) })
            else { return }
            let bodyEnd = reader.offset + size

            switch elementID {
            case ID.timestampScale:
                if let scale = reader.readUInt(length: size) { state.timestampScale = Double(scale) }
            case ID.duration:
                state.rawDuration = reader.readFloat(length: size)
            case ID.title:
                state.segmentTitle = reader.readString(length: size)
            default:
                break
            }
            reader.seek(to: bodyEnd)
        }
    }

    private func walkChapters(_ reader: inout EBMLReader, until end: Int, into state: inout ParseState) throws {
        while reader.offset < end {
            guard let elementID = try? reader.readElementID(),
                  let size = try? reader.readSize().map({ Int($0) })
            else { return }
            let bodyEnd = reader.offset + size

            if elementID == ID.chapterAtom {
                if let chapter = readChapterAtom(&reader, until: bodyEnd) {
                    state.chapters.append(chapter)
                }
            } else if elementID == ID.editionEntry {
                try walkChapters(&reader, until: bodyEnd, into: &state)
            }
            reader.seek(to: bodyEnd)
        }
    }

    /// Chapter times are absolute nanoseconds, independent of TimestampScale.
    private func readChapterAtom(_ reader: inout EBMLReader, until end: Int) -> Chapter? {
        var start: TimeInterval?
        var title: String?

        while reader.offset < end {
            guard let elementID = try? reader.readElementID(),
                  let size = try? reader.readSize().map({ Int($0) })
            else { return nil }
            let bodyEnd = reader.offset + size

            switch elementID {
            case ID.chapterTimeStart:
                start = reader.readUInt(length: size).map { Double($0) / 1_000_000_000 }
            case ID.chapterDisplay:
                while reader.offset < bodyEnd {
                    guard let displayID = try? reader.readElementID(),
                          let displaySize = try? reader.readSize().map({ Int($0) })
                    else { break }
                    let displayEnd = reader.offset + displaySize
                    if displayID == ID.chapterString, title == nil {
                        title = reader.readString(length: displaySize)
                    }
                    reader.seek(to: displayEnd)
                }
            default:
                break
            }
            reader.seek(to: bodyEnd)
        }

        guard let start else { return nil }
        // Titles are optional in Matroska, and ripped films routinely omit them;
        // numbering happens once the chapters are sorted.
        return Chapter(index: 0, start: start, title: title ?? "")
    }

    private func walkTags(_ reader: inout EBMLReader, until end: Int, into state: inout ParseState) throws {
        while reader.offset < end {
            guard let elementID = try? reader.readElementID(),
                  let size = try? reader.readSize().map({ Int($0) })
            else { return }
            let bodyEnd = reader.offset + size
            if elementID == ID.tag { readTag(&reader, until: bodyEnd, into: &state) }
            reader.seek(to: bodyEnd)
        }
    }

    /// One `Tag` element: a target level plus the `SimpleTag`s it applies to.
    /// The level is what separates "this series is called Twin Peaks" from
    /// "this episode is called Northwest Passage".
    private func readTag(_ reader: inout EBMLReader, until end: Int, into state: inout ParseState) {
        var level = MatroskaKeyMap.defaultTargetLevel
        var isTrackScoped = false
        var pairs: [(String, String)] = []

        while reader.offset < end {
            guard let elementID = try? reader.readElementID(),
                  let size = try? reader.readSize().map({ Int($0) })
            else { return }
            let bodyEnd = reader.offset + size

            switch elementID {
            case ID.targets:
                while reader.offset < bodyEnd {
                    guard let targetID = try? reader.readElementID(),
                          let targetSize = try? reader.readSize().map({ Int($0) })
                    else { break }
                    let targetEnd = reader.offset + targetSize
                    if targetID == ID.targetTypeValue,
                       let value = reader.readUInt(length: targetSize) {
                        level = Int(value)
                    }
                    // A tag aimed at a track describes the encoding, not the
                    // work: mkvmerge's BPS/NUMBER_OF_FRAMES statistics live here.
                    if targetID == ID.tagTrackUID { isTrackScoped = true }
                    reader.seek(to: targetEnd)
                }
            case ID.simpleTag:
                var name: String?
                var value: String?
                while reader.offset < bodyEnd {
                    guard let fieldID = try? reader.readElementID(),
                          let fieldSize = try? reader.readSize().map({ Int($0) })
                    else { break }
                    let fieldEnd = reader.offset + fieldSize
                    if fieldID == ID.tagName { name = reader.readString(length: fieldSize) }
                    if fieldID == ID.tagString { value = reader.readString(length: fieldSize) }
                    reader.seek(to: fieldEnd)
                }
                if let name, let value, !value.isEmpty { pairs.append((name, value)) }
            default:
                break
            }
            reader.seek(to: bodyEnd)
        }

        guard !isTrackScoped else { return }
        for (name, value) in pairs {
            guard let key = MatroskaKeyMap.key(for: name, targetLevel: level) else { continue }
            state.tags[key] = MatroskaKeyMap.value(value, for: key)
        }
    }

    private func walkAttachments(_ reader: inout EBMLReader, until end: Int, into state: inout ParseState) throws {
        while reader.offset < end {
            guard let elementID = try? reader.readElementID(),
                  let size = try? reader.readSize().map({ Int($0) })
            else { return }
            let bodyEnd = reader.offset + size

            if elementID == ID.attachedFile {
                var mimeType: String?
                var payload: Data?
                while reader.offset < bodyEnd {
                    guard let fieldID = try? reader.readElementID(),
                          let fieldSize = try? reader.readSize().map({ Int($0) })
                    else { break }
                    let fieldEnd = reader.offset + fieldSize
                    if fieldID == ID.fileMimeType { mimeType = reader.readString(length: fieldSize) }
                    if fieldID == ID.fileData { payload = reader.readData(length: fieldSize) }
                    reader.seek(to: fieldEnd)
                }
                if let payload, let mimeType, mimeType.hasPrefix("image/") {
                    state.artwork.append(Artwork(role: .poster, data: payload, mimeType: mimeType))
                }
            }
            reader.seek(to: bodyEnd)
        }
    }
}
