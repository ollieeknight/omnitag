import Compression
import Foundation

/// A zip reader and writer, because EPUB is a zip and Foundation has no zip API.
///
/// Only what a tagger needs: list the entries, inflate one of them, and rebuild
/// the archive with one entry replaced. Rebuilding copies every other entry's
/// *already-compressed* bytes verbatim — nothing is re-encoded, so the rest of
/// the book comes out byte-identical and a 300 MB illustrated EPUB costs a copy
/// rather than a recompression.
///
/// Zip64 is not handled: an EPUB with more than 65,535 entries or a member over
/// 4 GB is refused rather than mis-parsed.
public struct ZipArchive: Sendable {
    public struct Entry: Sendable {
        public let path: String
        public let isStored: Bool
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let crc32: UInt32
        /// Offset of the local header, not of the payload: the payload's own
        /// offset depends on the local header's name and extra fields, which
        /// are allowed to differ from the central directory's.
        let localHeaderOffset: Int
    }

    public struct NewEntry: Sendable {
        public let path: String
        public let data: Data
        /// EPUB requires `mimetype` stored, first, and with no extra field.
        public let stored: Bool

        public init(path: String, data: Data, stored: Bool? = nil) {
            self.path = path
            self.data = data
            self.stored = stored ?? (path == "mimetype")
        }
    }

    public let entries: [Entry]
    private let bytes: [UInt8]

    public var paths: [String] { entries.map(\.path) }

    // ponytail: reads the whole archive into memory. Fine for a book — the
    // developer's largest is 3.4 MB — but a 300 MB illustrated EPUB would cost
    // that twice. Read entries through a FileHandle if one ever turns up.
    public init(url: URL) throws {
        try self.init(Data(contentsOf: url, options: .mappedIfSafe), name: url.lastPathComponent)
    }

    public init(_ data: Data, name: String = "archive") throws {
        bytes = [UInt8](data)
        entries = try Self.parseCentralDirectory(bytes, name: name)
    }

    // MARK: - Reading

    public func contains(_ path: String) -> Bool { entries.contains { $0.path == path } }

    /// The decompressed contents of one entry.
    public func data(at path: String) throws -> Data {
        guard let entry = entries.first(where: { $0.path == path }) else {
            throw ZipError.entryNotFound(path)
        }
        return try decompress(entry)
    }

    /// The first entry whose path matches, case-insensitively — EPUB paths in
    /// the OPF are case-sensitive in the spec and not always in practice.
    public func firstData(matching predicate: (String) -> Bool) throws -> Data? {
        guard let entry = entries.first(where: { predicate($0.path) }) else { return nil }
        return try decompress(entry)
    }

    private func decompress(_ entry: Entry) throws -> Data {
        let payload = try payloadRange(of: entry)
        if entry.isStored { return Data(bytes[payload]) }
        guard entry.uncompressedSize > 0 else { return Data() }

        var destination = [UInt8](repeating: 0, count: entry.uncompressedSize)
        let written = bytes.withUnsafeBufferPointer { source -> Int in
            compression_decode_buffer(
                &destination, entry.uncompressedSize,
                source.baseAddress! + payload.lowerBound, payload.count,
                nil, COMPRESSION_ZLIB)
        }
        guard written == entry.uncompressedSize else {
            throw ZipError.corrupt("inflating \(entry.path) produced \(written) of \(entry.uncompressedSize) bytes")
        }
        return Data(destination)
    }

    /// The compressed bytes exactly as they sit in the file, for verbatim copy.
    private func compressedBytes(of entry: Entry) throws -> ArraySlice<UInt8> {
        bytes[try payloadRange(of: entry)]
    }

    private func payloadRange(of entry: Entry) throws -> Range<Int> {
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, u32(header) == 0x0403_4b50 else {
            throw ZipError.corrupt("bad local header for \(entry.path)")
        }
        let start = header + 30 + u16(header + 26) + u16(header + 28)
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ZipError.corrupt("\(entry.path) runs past the end of the file") }
        return start..<end
    }

    // MARK: - Writing

    /// Rebuild this archive somewhere else, replacing the named entries. Every
    /// other entry keeps its original compressed bytes.
    public func rebuild(to url: URL, replacing replacements: [String: Data]) throws {
        var output = Data()
        var directory = Data()
        var count = 0

        for entry in entries {
            let offset = output.count
            if let replacement = replacements[entry.path] {
                let new = NewEntry(path: entry.path, data: replacement, stored: entry.isStored)
                let (local, central) = Self.serialise(new, offset: offset)
                output.append(local)
                directory.append(central)
            } else {
                let payload = try compressedBytes(of: entry)
                let (local, central) = Self.serialiseVerbatim(entry, payload: Data(payload), offset: offset)
                output.append(local)
                directory.append(central)
            }
            count += 1
        }

        output.append(directory)
        output.append(Self.endOfCentralDirectory(
            count: count, directorySize: directory.count,
            directoryOffset: output.count - directory.count))
        try output.write(to: url, options: .atomic)
    }

    /// Write a fresh archive. `mimetype`, if present, is forced first and stored.
    public static func write(_ newEntries: [NewEntry], to url: URL) throws {
        var ordered = newEntries
        if let index = ordered.firstIndex(where: { $0.path == "mimetype" }), index != 0 {
            ordered.insert(ordered.remove(at: index), at: 0)
        }

        var output = Data()
        var directory = Data()
        for entry in ordered {
            let (local, central) = serialise(entry, offset: output.count)
            output.append(local)
            directory.append(central)
        }
        output.append(directory)
        output.append(endOfCentralDirectory(
            count: ordered.count, directorySize: directory.count,
            directoryOffset: output.count - directory.count))
        try output.write(to: url, options: .atomic)
    }

    private static func serialise(_ entry: NewEntry, offset: Int) -> (local: Data, central: Data) {
        let name = Data(entry.path.utf8)
        let crc = CRC32.checksum(entry.data)
        let payload = entry.stored ? entry.data : (deflate(entry.data) ?? entry.data)
        // A payload deflate could not shrink is stored instead: never write a
        // deflate stream larger than the data it encodes.
        let stored = entry.stored || payload.count >= entry.data.count
        let body = stored ? entry.data : payload

        var local = Data()
        local.append(u32: 0x0403_4b50)
        local.append(u16: 20)                        // version needed
        local.append(u16: 0)                         // flags
        local.append(u16: stored ? 0 : 8)            // method
        local.append(u16: 0); local.append(u16: 0)   // dos time, date
        local.append(u32: crc)
        local.append(u32: UInt32(body.count))
        local.append(u32: UInt32(entry.data.count))
        local.append(u16: name.count)
        local.append(u16: 0)                         // no extra field: EPUB wants none on mimetype
        local.append(name)
        local.append(body)

        var central = Data()
        central.append(u32: 0x0201_4b50)
        central.append(u16: 20)                      // version made by
        central.append(u16: 20)                      // version needed
        central.append(u16: 0)
        central.append(u16: stored ? 0 : 8)
        central.append(u16: 0); central.append(u16: 0)
        central.append(u32: crc)
        central.append(u32: UInt32(body.count))
        central.append(u32: UInt32(entry.data.count))
        central.append(u16: name.count)
        central.append(u16: 0); central.append(u16: 0)  // extra, comment
        central.append(u16: 0); central.append(u16: 0)  // disk, internal attrs
        central.append(u32: 0)                          // external attrs
        central.append(u32: UInt32(offset))
        central.append(name)

        return (local, central)
    }

    /// Re-emit an entry we are not changing, reusing its compressed payload.
    private static func serialiseVerbatim(_ entry: Entry, payload: Data, offset: Int) -> (local: Data, central: Data) {
        let name = Data(entry.path.utf8)

        var local = Data()
        local.append(u32: 0x0403_4b50)
        local.append(u16: 20)
        local.append(u16: 0)
        local.append(u16: entry.isStored ? 0 : 8)
        local.append(u16: 0); local.append(u16: 0)
        local.append(u32: entry.crc32)
        local.append(u32: UInt32(entry.compressedSize))
        local.append(u32: UInt32(entry.uncompressedSize))
        local.append(u16: name.count)
        local.append(u16: 0)
        local.append(name)
        local.append(payload)

        var central = Data()
        central.append(u32: 0x0201_4b50)
        central.append(u16: 20)
        central.append(u16: 20)
        central.append(u16: 0)
        central.append(u16: entry.isStored ? 0 : 8)
        central.append(u16: 0); central.append(u16: 0)
        central.append(u32: entry.crc32)
        central.append(u32: UInt32(entry.compressedSize))
        central.append(u32: UInt32(entry.uncompressedSize))
        central.append(u16: name.count)
        central.append(u16: 0); central.append(u16: 0)
        central.append(u16: 0); central.append(u16: 0)
        central.append(u32: 0)
        central.append(u32: UInt32(offset))
        central.append(name)

        return (local, central)
    }

    private static func endOfCentralDirectory(count: Int, directorySize: Int, directoryOffset: Int) -> Data {
        var record = Data()
        record.append(u32: 0x0605_4b50)
        record.append(u16: 0); record.append(u16: 0)     // this disk, directory disk
        record.append(u16: count); record.append(u16: count)
        record.append(u32: UInt32(directorySize))
        record.append(u32: UInt32(directoryOffset))
        record.append(u16: 0)                             // comment length
        return record
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let source = [UInt8](data)
        var destination = [UInt8](repeating: 0, count: max(64, source.count))
        let written = source.withUnsafeBufferPointer { input in
            compression_encode_buffer(
                &destination, destination.count,
                input.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(destination.prefix(written))
    }

    // MARK: - Central directory

    private static func parseCentralDirectory(_ bytes: [UInt8], name: String) throws -> [Entry] {
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }

        guard bytes.count > 22 else { throw ZipError.notAnArchive(name) }

        // The end-of-central-directory record sits at the end, after a comment
        // of up to 64 KB, so it is found by scanning backwards for its signature.
        var end = bytes.count - 22
        let limit = max(0, bytes.count - 22 - 0xFFFF)
        while end >= limit, u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= limit, end >= 0 else { throw ZipError.notAnArchive(name) }

        let count = u16(end + 10)
        var offset = u32(end + 16)
        guard count != 0xFFFF, offset != 0xFFFF_FFFF else { throw ZipError.zip64(name) }

        var parsed: [Entry] = []
        parsed.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4b50 else {
                throw ZipError.corrupt("central directory of \(name) is malformed")
            }
            let method = u16(offset + 10)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            guard offset + 46 + nameLength <= bytes.count else {
                throw ZipError.corrupt("entry name of \(name) runs past the end")
            }
            guard method == 0 || method == 8 else {
                throw ZipError.unsupportedCompression(method)
            }
            parsed.append(Entry(
                path: String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self),
                isStored: method == 0,
                compressedSize: u32(offset + 20),
                uncompressedSize: u32(offset + 24),
                crc32: UInt32(u32(offset + 16)),
                localHeaderOffset: u32(offset + 42)))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return parsed
    }

    private func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
    private func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
}

public enum ZipError: Error, LocalizedError {
    case notAnArchive(String)
    case entryNotFound(String)
    case corrupt(String)
    case zip64(String)
    case unsupportedCompression(Int)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive(let name): "\(name) is not a zip archive"
        case .entryNotFound(let path): "the archive has no entry at \(path)"
        case .corrupt(let detail): detail
        case .zip64(let name): "\(name) uses Zip64, which OmniTag cannot read yet"
        case .unsupportedCompression(let method):
            "the archive uses compression method \(method); only stored and deflate are supported"
        }
    }
}

/// The zip checksum. Table built once, because an EPUB has hundreds of entries.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        (0..<8).reduce(UInt32(index)) { value, _ in
            value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(u16 value: Int) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
    mutating func append(u32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
    mutating func append(u32 value: Int) { append(u32: UInt32(value)) }
}
