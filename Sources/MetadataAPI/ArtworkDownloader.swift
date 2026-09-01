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
        
        guard !data.isEmpty else { throw MetadataError.server(status: status) }
        return Artwork(role: .cover, data: data, mimeType: Artwork.sniffMimeType(data))
    }
}
