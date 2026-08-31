import Foundation
import MediaCore

/// ID3v2 tag structure: parsing, serialising, and the two integer encodings the
/// format uses. An mp3 is `[ID3v2 tag][audio frames][optional ID3v1 trailer]`,
/// so editing tags means rebuilding the front block and leaving the rest alone.
enum ID3v2 {
    // MARK: integers

    /// Synchsafe: 7 bits per byte, so a size can never contain `0xFF` and be
    /// mistaken for an MPEG frame sync. Used for the tag size in every version,
    /// and for frame sizes in v2.4 only — the v2.3 trap that corrupts parsers.
    static func synchsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
         UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    static func desynchsafe(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    static func bigEndian(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { $0 << 8 | Int($1) }
    }

    // MARK: model

    struct Frame: Equatable {
        var id: String
        var flags: [UInt8]
        var payload: Data

        /// Text frames start with an encoding byte. Everything else is opaque
        /// bytes we carry around without interpreting.
        var textValue: String? {
            guard id.hasPrefix("T") || id == "COMM", let encoding = payload.first else { return nil }
            let body = payload.dropFirst()
            let text: String? = switch encoding {
            case 0x00: String(data: body, encoding: .isoLatin1)
            case 0x01: String(data: body, encoding: .utf16)
            case 0x02: String(data: body, encoding: .utf16BigEndian)
            default: String(data: body, encoding: .utf8)
            }
            return text?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }

        static func text(_ id: String, _ value: String) -> Frame {
            Frame(id: id, flags: [0, 0], payload: Data([0x03] + Array(value.utf8)))
        }
    }

    struct Tag {
        var version: UInt8
        var flags: UInt8
        var frames: [Frame]
        /// Header + body, i.e. the offset at which the audio starts.
        var totalSize: Int

        var isUnsynchronised: Bool { flags & 0x80 != 0 }
        var hasExtendedHeader: Bool { flags & 0x40 != 0 }
    }

    // MARK: parsing

    static let headerSize = 10

    /// `nil` when the file has no ID3v2 tag — a legitimate state, not an error.
    static func parse(_ data: Data) -> Tag? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data.prefix(headerSize))
        guard bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return nil }  // "ID3"

        let version = bytes[3]
        let flags = bytes[5]
        let bodySize = desynchsafe(Array(bytes[6..<10]))
        let totalSize = headerSize + bodySize
        guard data.count >= totalSize else { return nil }

        var tag = Tag(version: version, flags: flags, frames: [], totalSize: totalSize)
        // v2.2 uses three-character ids and a different frame layout; an
        // unsynchronised tag needs de-unsynchronisation before frames make
        // sense. Both are refused by the writer rather than parsed half-right.
        guard version >= 3, flags & 0x80 == 0 else { return tag }

        var cursor = headerSize
        if tag.hasExtendedHeader, data.count >= cursor + 4 {
            let size = Array(data[(data.startIndex + cursor)..<(data.startIndex + cursor + 4)])
            cursor += version >= 4 ? desynchsafe(size) : bigEndian(size) + 4
        }

        while cursor + 10 <= totalSize {
            let start = data.startIndex + cursor
            let idBytes = Array(data[start..<(start + 4)])
            // Padding: the rest of the body is zeroes, and frames are finished.
            guard idBytes[0] != 0 else { break }
            guard let id = String(bytes: idBytes, encoding: .isoLatin1) else { break }

            let sizeBytes = Array(data[(start + 4)..<(start + 8)])
            // v2.4 sizes are synchsafe, v2.3 sizes are plain. Reading one as the
            // other silently truncates every frame past the first large one.
            let size = version >= 4 ? desynchsafe(sizeBytes) : bigEndian(sizeBytes)
            let frameFlags = Array(data[(start + 8)..<(start + 10)])
            let payloadStart = cursor + 10
            guard size >= 0, payloadStart + size <= totalSize else { break }

            let payload = data[(data.startIndex + payloadStart)..<(data.startIndex + payloadStart + size)]
            tag.frames.append(Frame(id: id, flags: frameFlags, payload: Data(payload)))
            cursor = payloadStart + size
        }
        return tag
    }

    /// Serialises a v2.4 tag, always UTF-8, with padding so a later small edit
    /// could be made in place.
    static func serialise(_ frames: [Frame], padding: Int = 1024) -> Data {
        var body = Data()
        for frame in frames {
            body.append(contentsOf: Array(frame.id.utf8))
            body.append(contentsOf: synchsafe(frame.payload.count))
            body.append(contentsOf: frame.flags.count == 2 ? frame.flags : [0, 0])
            body.append(frame.payload)
        }
        body.append(Data(count: padding))

        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x04, 0x00, 0x00])
        tag.append(contentsOf: synchsafe(body.count))
        tag.append(body)
        return tag
    }

    // MARK: mapping

    /// Frames → `TagSet`, using the same table the AVFoundation path uses.
    static func tagSet(from tag: Tag) throws -> TagSet {
        var tags = TagSet()
        for frame in tag.frames {
            guard let value = frame.textValue, !value.isEmpty else { continue }
            if let pair = ID3KeyMap.pairedFrames[frame.id] {
                let (index, total) = ID3KeyMap.split(value)
                if let index { tags[pair.index] = .number(index) }
                if let total { tags[pair.total] = .number(total) }
                continue
            }
            let key = ID3KeyMap.key(forIdentifier: "id3/\(frame.id)")
            tags[key] = ID3KeyMap.value(value, for: key)
        }
        return tags
    }

    /// Merges `tags` into the frames of an existing tag: managed frames are
    /// replaced or removed, everything else is carried across untouched.
    static func merge(_ tags: TagSet, into existing: [Frame]) -> [Frame] {
        var frames = existing.filter { !ID3KeyMap.managedFrameIDs.contains($0.id) }

        for (frameID, key) in ID3KeyMap.writeFrames {
            if let pair = ID3KeyMap.pairedFrames[frameID] {
                let index = tags[pair.index]?.intValue
                let total = tags[pair.total]?.intValue
                guard index != nil || total != nil else { continue }
                let text = total.map { "\(index ?? 0)/\($0)" } ?? "\(index ?? 0)"
                frames.append(.text(frameID, text))
            } else if let value = tags[key]?.stringValue, !value.isEmpty {
                frames.append(.text(frameID, value))
            }
        }

        // Anything the domain model does not name, written as a user-defined
        // TXXX frame so a round-trip through OmniTag stays lossless.
        for (key, value) in tags.values {
            guard case .custom(let name) = key, !name.hasPrefix("id3/"),
                  let text = value.stringValue
            else { continue }
            frames.append(Frame(
                id: "TXXX", flags: [0, 0],
                payload: Data([0x03] + Array(name.utf8) + [0x00] + Array(text.utf8))))
        }

        return frames.sorted { $0.id < $1.id }
    }
}
