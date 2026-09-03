import Foundation
@testable import TagIO
import Testing

@Suite("EBML primitives")
struct EBMLTests {
    /// One byte pattern and the number it should decode to.
    struct Case: Sendable {
        var bytes: [UInt8]
        var expected: UInt64
        init(_ bytes: [UInt8], _ expected: UInt64) {
            self.bytes = bytes
            self.expected = expected
        }
    }

    @Test("decodes element IDs, keeping the marker bit that identifies them",
          arguments: [
              Case([0x1A, 0x45, 0xDF, 0xA3], 0x1A45_DFA3), // EBML header
              Case([0x18, 0x53, 0x80, 0x67], 0x1853_8067), // Segment
              Case([0x42, 0x86], 0x4286), // EBMLVersion
              Case([0xA3], 0xA3) // SimpleBlock
          ])
    func decodesElementID(_ testCase: Case) throws {
        var reader = EBMLReader(Data(testCase.bytes))
        #expect(try reader.readElementID() == testCase.expected)
    }

    @Test("decodes sizes, stripping the length marker",
          arguments: [
              Case([0x82], 2),
              Case([0x40, 0x02], 2),
              Case([0x20, 0x00, 0x02], 2),
              Case([0x41, 0xF4], 500)
          ])
    func decodesSize(_ testCase: Case) throws {
        var reader = EBMLReader(Data(testCase.bytes))
        #expect(try reader.readSize() == testCase.expected)
    }

    @Test("treats an all-ones size as unknown, not as a huge length")
    func unknownSize() throws {
        var reader = EBMLReader(Data([0xFF]))
        #expect(try reader.readSize() == nil)
    }

    @Test("reads unsigned integers of any width")
    func readsUInt() {
        var reader = EBMLReader(Data([0x01, 0x00, 0x00]))
        #expect(reader.readUInt(length: 3) == 65536)
    }

    @Test("reads floats in both widths")
    func readsFloat() {
        var four = EBMLReader(Data([0x40, 0x49, 0x0F, 0xDB]))
        #expect(abs((four.readFloat(length: 4) ?? 0) - 3.14159) < 0.0001)

        var eight = EBMLReader(Data([0x40, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18]))
        #expect(abs((eight.readFloat(length: 8) ?? 0) - 3.14159265) < 0.0000001)
    }

    @Test("reads UTF-8 strings and drops the null padding Matroska allows")
    func readsString() {
        var reader = EBMLReader(Data(Array("Twin Peaks".utf8) + [0x00, 0x00]))
        #expect(reader.readString(length: 12) == "Twin Peaks")
    }

    @Test("refuses truncated input instead of reading past the end")
    func rejectsTruncation() {
        var reader = EBMLReader(Data([0x1A, 0x45]))
        #expect(throws: (any Error).self) { try reader.readElementID() }
    }
}
