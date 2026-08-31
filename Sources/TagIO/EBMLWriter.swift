import Foundation

/// The write half of `EBMLReader`. Small on purpose: Matroska editing means
/// rebuilding two or three elements, never the file.
enum EBMLWriter {
    /// Element ids are written as-is — the marker bit is part of the id.
    static func id(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        while remaining > 0 { bytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 }
        return bytes.isEmpty ? [0] : bytes
    }

    /// Size VINT. `width` forces a wider-than-minimal encoding, which EBML
    /// allows and which is how an element is grown by a byte or two to make a
    /// leftover gap paddable.
    static func size(_ value: Int, width forced: Int? = nil) -> [UInt8] {
        let width = forced ?? (1...8).first { value < (1 << (7 * $0)) - 1 } ?? 8
        var bytes = (0..<width).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) }
        bytes[0] |= UInt8(0x80 >> (width - 1))
        return bytes
    }

    static func element(_ elementID: UInt64, _ payload: [UInt8]) -> [UInt8] {
        id(elementID) + size(payload.count) + payload
    }

    static func string(_ elementID: UInt64, _ value: String) -> [UInt8] {
        element(elementID, Array(value.utf8))
    }

    static func uint(_ elementID: UInt64, _ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat { bytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 } while remaining > 0
        return element(elementID, bytes)
    }

    /// Padding that fills a gap exactly. `nil` when the gap is one byte, which
    /// cannot hold even an empty Void — callers grow the previous element's size
    /// VINT instead.
    static func void(totalLength: Int) -> [UInt8]? {
        guard totalLength >= 2 else { return nil }
        // Try each size-VINT width until id + size + payload lands exactly.
        // An all-ones size means "unknown length" in EBML, so a payload of
        // exactly 2^(7w)-1 is unusable at that width.
        for width in 1...8 {
            let payload = totalLength - 1 - width
            guard payload >= 0 else { break }
            guard payload < (1 << (7 * width)) - 1 else { continue }
            return [0xEC] + size(payload, width: width) + [UInt8](repeating: 0, count: payload)
        }
        return nil
    }
}
