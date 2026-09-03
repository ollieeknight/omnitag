import Foundation
import ImageIO
import MediaCore
import UniformTypeIdentifiers

/// Prepares an image for embedding as cover art.
///
/// Validates image bytes via ImageIO. By default, original resolution and format
/// are preserved untouched. Downsampling to JPEG is opt-in when `maxPixels` is provided.
public enum CoverImage {
    /// Suggested limit when downsampling is desired.
    public static let defaultMaxPixels = 1400
    public static let quality = 0.85

    /// The bytes to embed, or `nil` if this is not an image at all.
    /// If `maxPixels` is nil, returns original bytes unchanged for valid images.
    public static func prepared(_ data: Data, maxPixels: Int? = nil) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        guard let limit = maxPixels else { return data }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(width, height) > limit else { return data }

        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return data }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return data }
        CGImageDestinationAddImage(
            destination, scaled,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return data }
        return output as Data
    }

    /// The same, expressed as the `Artwork` the engine stores.
    public static func artwork(from data: Data, role: Artwork.Role = .cover, maxPixels: Int? = nil) -> Artwork? {
        guard let prepared = prepared(data, maxPixels: maxPixels) else { return nil }
        return Artwork(role: role, data: prepared, mimeType: Artwork.sniffMimeType(prepared))
    }
}
