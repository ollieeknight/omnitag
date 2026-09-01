import Foundation
import ImageIO
import MediaCore
import UniformTypeIdentifiers

/// Prepares an image for embedding as cover art.
///
/// Covers arrive at 3000 px from Audible and from people's own folders. Writing
/// one of those verbatim into each of a 30-part audiobook is how a library
/// balloons, so anything larger than `maxPixels` is resampled to JPEG. Anything
/// already small enough is passed through byte-for-byte: re-encoding a cover
/// that did not need it only loses quality.
public enum CoverImage {
    /// Comfortably above what any player renders, well below poster size.
    public static let maxPixels = 1400
    public static let quality = 0.85

    /// The bytes to embed, or `nil` if this is not an image at all.
    public static func prepared(_ data: Data, maxPixels: Int = CoverImage.maxPixels) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(width, height) > maxPixels else { return data }

        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary) else { return data }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return data }
        CGImageDestinationAddImage(
            destination, scaled,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return data }
        return output as Data
    }

    /// The same, expressed as the `Artwork` the engine stores.
    public static func artwork(from data: Data, role: Artwork.Role = .cover) -> Artwork? {
        guard let prepared = prepared(data) else { return nil }
        return Artwork(role: role, data: prepared, mimeType: Artwork.sniffMimeType(prepared))
    }
}
