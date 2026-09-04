import Foundation
import MediaCore

/// The iTunes Search API behind `MetadataProvider`, serving music — the last
/// kind that had no provider at all.
///
/// No key, no account, no region picker: unlike Audible's storefronts, the
/// search endpoint answers the same catalogue for everyone (a `country`
/// parameter exists but only changes pricing and availability, not the
/// metadata OmniTag writes).
public struct ITunesProvider: MetadataProvider {
    private let client: ITunesClient

    public init(transport: (any HTTPTransporting)? = nil) {
        client = transport.map { ITunesClient(transport: $0) } ?? ITunesClient()
    }

    public var id: String {
        "itunes"
    }

    public var name: String {
        "iTunes"
    }

    public var kinds: Set<MediaKind> {
        [.music]
    }

    public var searchHint: String {
        "Title, artist or album"
    }

    public func search(_ query: MetadataQuery, kind _: MediaKind, limit: Int) async throws -> [MetadataCandidate] {
        try await client.searchSongs(query, limit: limit)
    }

    public func details(for candidate: MetadataCandidate, kind _: MediaKind) async throws -> MetadataDetails {
        await client.details(for: candidate)
    }
}
