import Foundation
@testable import TagIO
import Testing

@Suite("EBMLWriter")
struct EBMLWriterTests {
    @Test("writes sizes as minimal-width VINTs that read back", arguments: [0, 1, 126, 127, 128, 16382, 16383, 100_000] as [Int])
    func sizeRoundTrip(value: Int) throws {
        let bytes = EBMLWriter.size(value)
        var reader = EBMLReader(Data(bytes))
        #expect(try reader.readSize() == UInt64(value))
    }

    @Test("can pad a size to a wider encoding, which is how an element grows by one byte")
    func widenedSize() throws {
        let wide = EBMLWriter.size(4, width: 4)
        #expect(wide.count == 4)
        var reader = EBMLReader(Data(wide))
        #expect(try reader.readSize() == 4)
    }

    @Test("round-trips an element through the reader")
    func elementRoundTrip() throws {
        let element = EBMLWriter.element(0x7BA9, Array("Twin Peaks".utf8))
        var reader = EBMLReader(Data(element))
        #expect(try reader.readElementID() == 0x7BA9)
        let size = try #require(try reader.readSize())
        #expect(reader.readString(length: Int(size)) == "Twin Peaks")
    }

    @Test("builds Void elements of an exact byte length", arguments: [2, 3, 4, 129, 5039] as [Int])
    func voidOfExactLength(length: Int) throws {
        let bytes = try #require(EBMLWriter.void(totalLength: length))
        #expect(bytes.count == length)
        var reader = EBMLReader(Data(bytes))
        #expect(try reader.readElementID() == 0xEC)
        let size = try #require(try reader.readSize())
        #expect(reader.offset + Int(size) == length)
    }

    @Test("a one-byte gap cannot hold a Void and is reported as impossible")
    func voidTooSmall() {
        #expect(EBMLWriter.void(totalLength: 1) == nil)
    }
}
