import AppKit
import MediaCore

/// Decodes cover art once per distinct image and remembers the result,
/// keyed on the file's URL plus a cheap hash of the artwork bytes — so a
/// changed cover naturally gets a fresh entry with no explicit invalidation
/// to remember at every write site. Owned by `LibraryModel`, not view
/// `@State`, so it survives the table's cells being recreated on scroll.
@MainActor
final class ThumbnailCache {
    private struct Key: Hashable {
        var url: URL
        var dataHash: Int
    }

    private var cache: [Key: NSImage] = [:]

    /// `nil` when the item has no artwork, or the bytes cannot be decoded as
    /// an image — the caller falls back to a placeholder either way.
    func image(for item: MediaItem) -> NSImage? {
        guard let data = item.artwork.first?.data else { return nil }
        let key = Key(url: item.url, dataHash: data.hashValue)
        if let cached = cache[key] {
            return cached
        }
        guard let decoded = NSImage(data: data) else { return nil }
        cache[key] = decoded
        return decoded
    }
}
