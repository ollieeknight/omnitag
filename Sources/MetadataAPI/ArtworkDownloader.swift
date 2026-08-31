import Foundation
import MediaCore

/// Fetches an image from a URL without modification.
/// Preserves the original file format and quality (no resizing),
/// as requested by the user, because audiobook providers already 
/// serve appropriately-sized artwork.
public struct ArtworkDownloader: Sendable {
    private let transport: any HTTPTransporting

    public init(transport: any HTTPTransporting = URLSessionTransport()) {
        self.transport = transport
    }

    public func download(from url: URL) async throws -> Artwork {
        let (data, status) = try await transport.data(from: url)
        
        guard status == 200 else {
            throw MetadataError.server(status: status)
        }
        
        let mimeType = detectMimeType(from: data)
        return Artwork(role: .cover, data: data, mimeType: mimeType)
    }
    
    private func detectMimeType(from data: Data) -> String {
        // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
        if data.count >= 8, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
            return "image/png"
        }
        // Default to jpeg if not explicitly PNG
        return "image/jpeg"
    }
}
