import CoreGraphics
import Foundation
import ImageIO
import MediaCore
import Testing
import UniformTypeIdentifiers
@testable import TagIO

@Suite("CoverImage")
struct CoverImageTests {
    /// A real PNG of the given size, so the tests exercise ImageIO rather than
    /// a hand-rolled header.
    private func png(_ side: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func pixelWidth(_ data: Data) throws -> Int {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return try #require(properties?[kCGImagePropertyPixelWidth] as? Int)
    }

    @Test("an oversized cover is resampled down to the limit")
    func resamplesOversized() throws {
        let prepared = try #require(CoverImage.prepared(try png(2400), maxPixels: 600))
        #expect(try pixelWidth(prepared) == 600)
    }

    @Test("a cover already small enough is passed through untouched")
    func passesThroughSmall() throws {
        let original = try png(400)
        #expect(CoverImage.prepared(original, maxPixels: 600) == original)
    }

    @Test("resampling actually shrinks the bytes written into every file")
    func resamplingSavesSpace() throws {
        let original = try png(2400)
        let prepared = try #require(CoverImage.prepared(original, maxPixels: 600))
        #expect(prepared.count < original.count)
    }

    @Test("anything that is not an image is refused, not embedded")
    func refusesNonImages() {
        #expect(CoverImage.prepared(Data("not an image".utf8)) == nil)
        #expect(CoverImage.prepared(Data()) == nil)
        #expect(CoverImage.artwork(from: Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test("the artwork it produces carries the MIME type of what it wrote")
    func artworkCarriesItsType() throws {
        let small = try #require(CoverImage.artwork(from: try png(200)))
        #expect(small.mimeType == "image/png")
        let resampled = try #require(CoverImage.artwork(from: try png(3000)))
        #expect(resampled.mimeType == "image/jpeg")
        #expect(resampled.role == .cover)
    }
}
