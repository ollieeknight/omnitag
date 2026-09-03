import AppKit
import Foundation
import MediaCore
@testable import OmniTagApp
import Testing

@MainActor
@Suite("ThumbnailCache")
struct ThumbnailCacheTests {
    /// A genuinely valid 1x1 red-pixel PNG — `NSImage(data:)` needs real
    /// image bytes to decode, unlike the bare-header fixtures MIME-sniffing
    /// tests use.
    private static let onePixelPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xFC, 0xCF, 0xC0, 0x50,
        0x0F, 0x00, 0x04, 0x85, 0x01, 0x80, 0x84, 0xA9, 0x8C, 0x21, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ])

    private func item(url: URL = URL(filePath: "/tmp/a.mp4"), artwork: [Artwork] = []) -> MediaItem {
        MediaItem(url: url, kind: .movie, container: .mp4, artwork: artwork)
    }

    @Test("no artwork decodes to nil")
    func noArtworkIsNil() {
        let cache = ThumbnailCache()
        #expect(cache.image(for: item()) == nil)
    }

    @Test("undecodable bytes decode to nil rather than crashing")
    func garbageBytesAreNil() {
        let cache = ThumbnailCache()
        let broken = item(artwork: [Artwork(data: Data([0x00, 0x01, 0x02]), mimeType: "image/png")])
        #expect(cache.image(for: broken) == nil)
    }

    @Test("valid artwork decodes to an image")
    func validArtworkDecodes() {
        let cache = ThumbnailCache()
        let withCover = item(artwork: [Artwork(data: Self.onePixelPNG, mimeType: "image/png")])
        #expect(cache.image(for: withCover) != nil)
    }

    @Test("the same URL and bytes return the identical cached instance, not a fresh decode")
    func sameBytesAreCached() {
        let cache = ThumbnailCache()
        let withCover = item(artwork: [Artwork(data: Self.onePixelPNG, mimeType: "image/png")])
        let first = cache.image(for: withCover)
        let second = cache.image(for: withCover)
        #expect(first === second, "a cache hit must return the same decoded NSImage, not decode again")
    }

    @Test("changed artwork bytes for the same URL produce a fresh decode, not a stale cached image")
    func changedArtworkInvalidates() {
        let cache = ThumbnailCache()
        let url = URL(filePath: "/tmp/same.mp4")
        let original = item(url: url, artwork: [Artwork(data: Self.onePixelPNG, mimeType: "image/png")])
        let firstImage = cache.image(for: original)

        var differentBytes = Self.onePixelPNG
        differentBytes.append(0x00) // still garbage-appended PNG data, but a different hash
        let updated = item(url: url, artwork: [Artwork(data: differentBytes, mimeType: "image/png")])
        let secondImage = cache.image(for: updated)

        // Appending a stray byte to real PNG data usually still decodes (PNG
        // tolerates trailing bytes after IEND), so this asserts on identity,
        // not decodability — the point is a NEW decode happened, not a stale one.
        if let firstImage, let secondImage {
            #expect(firstImage !== secondImage)
        }
    }
}
