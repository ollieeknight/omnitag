import Foundation

/// Matroska is EBML: a binary tree of `(id, size, payload)` elements where both
/// the id and the size are variable-length integers. Everything OmniTag needs
/// from an mkv — title, tags, chapters, duration — is a handful of elements
/// near the front, so a small cursor over a `Data` slice is the whole parser.
///
/// The distinction that catches people out: an **id** keeps its length-marker
/// bit (`0x1A45DFA3` really is the EBML header id), while a **size** strips it.
struct EBMLReader {
    enum Failure: Error, Equatable {
        case truncated
        case invalidVINT
    }

    private let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var isAtEnd: Bool { offset >= data.count }
    var remaining: Int { max(0, data.count - offset) }

    mutating func seek(to newOffset: Int) { offset = newOffset }
    mutating func skip(_ count: Int) { offset += count }

    private mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw Failure.truncated }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    /// Number of bytes the VINT occupies, from the position of its first set bit.
    private static func width(of first: UInt8) throws -> Int {
        guard first != 0 else { throw Failure.invalidVINT }
        return 8 - Int(log2(Double(first)).rounded(.down))
    }

    /// Element id: marker bit retained, because the id *is* the whole byte pattern.
    mutating func readElementID() throws -> UInt64 {
        let first = try byte()
        let width = try Self.width(of: first)
        var value = UInt64(first)
        for _ in 1..<width { value = value << 8 | UInt64(try byte()) }
        return value
    }

    /// Element size: marker bit stripped. `nil` means "unknown size", which
    /// Matroska uses for live-streamed segments and clusters.
    mutating func readSize() throws -> UInt64? {
        let first = try byte()
        let width = try Self.width(of: first)
        var value = UInt64(first & (0xFF >> UInt8(width)))
        var allOnes = value == UInt64(0xFF >> UInt8(width))
        for _ in 1..<width {
            let next = try byte()
            allOnes = allOnes && next == 0xFF
            value = value << 8 | UInt64(next)
        }
        return allOnes ? nil : value
    }

    mutating func readUInt(length: Int) -> UInt64? {
        guard length > 0, length <= 8, remaining >= length else { return nil }
        var value: UInt64 = 0
        for _ in 0..<length { value = value << 8 | UInt64((try? byte()) ?? 0) }
        return value
    }

    mutating func readFloat(length: Int) -> Double? {
        switch length {
        case 4: readUInt(length: 4).map { Double(Float(bitPattern: UInt32($0))) }
        case 8: readUInt(length: 8).map { Double(bitPattern: $0) }
        default: nil
        }
    }

    /// Matroska pads strings with NULs rather than trimming the element.
    mutating func readString(length: Int) -> String? {
        guard remaining >= length else { return nil }
        let start = data.startIndex + offset
        offset += length
        let bytes = data[start..<(start + length)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readData(length: Int) -> Data? {
        guard remaining >= length else { return nil }
        let start = data.startIndex + offset
        offset += length
        return Data(data[start..<(start + length)])
    }
}
