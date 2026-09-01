import Foundation
import MediaCore

/// One metadata service, expressed the way the wizard needs it.
///
/// The wizard knows nothing about Audible or OpenLibrary: it asks which
/// providers serve the tab the user is on, and drives whichever they pick.
/// Adding TMDB later means conforming a type here and nothing else.
public protocol MetadataProvider: Sendable {
    /// Stable, for preference storage. Not shown to anyone.
    var id: String { get }
    /// Shown in the wizard's provider menu.
    var name: String { get }
    /// The tabs this provider can answer for.
    var kinds: Set<MediaKind> { get }
    /// What to put in the search field's placeholder — the accepted inputs
    /// differ enough per service that a generic string would mislead.
    var searchHint: String { get }

    func search(_ query: MetadataQuery, limit: Int) async throws -> [MetadataCandidate]
    func details(for candidate: MetadataCandidate) async throws -> MetadataDetails
}

public extension MetadataProvider {
    func search(_ query: MetadataQuery) async throws -> [MetadataCandidate] {
        try await search(query, limit: 20)
    }
}

/// Audible search plus Audnexus detail and chapters, behind the protocol.
/// Region lives on the provider because it is Audible's concept, not the
/// wizard's — OpenLibrary has no storefronts.
public struct AudibleMetadataProvider: MetadataProvider {
    public let region: AudibleRegion
    private let service: AudibleProvider

    public init(region: AudibleRegion = .unitedKingdom, transport: (any HTTPTransporting)? = nil) {
        self.region = region
        self.service = transport.map { AudibleProvider(region: region, transport: $0) }
            ?? AudibleProvider(region: region)
    }

    public var id: String { "audible.\(region.rawValue)" }
    public var name: String { "Audible \(region.rawValue.uppercased())" }
    public var kinds: Set<MediaKind> { [.audiobook] }
    public var searchHint: String { "Title, author, ASIN or Audible link" }

    public func search(_ query: MetadataQuery, limit: Int) async throws -> [MetadataCandidate] {
        try await service.search(query, limit: limit)
    }

    public func details(for candidate: MetadataCandidate) async throws -> MetadataDetails {
        try await service.details(for: candidate.id)
    }
}

/// OpenLibrary: no key, no storefronts, and the only free catalogue that covers
/// print books rather than audio editions.
public struct OpenLibraryProvider: MetadataProvider {
    private let client: OpenLibraryClient

    public init(transport: (any HTTPTransporting)? = nil) {
        self.client = transport.map { OpenLibraryClient(transport: $0) } ?? OpenLibraryClient()
    }

    public var id: String { "openlibrary" }
    public var name: String { "OpenLibrary" }
    public var kinds: Set<MediaKind> { [.book] }
    public var searchHint: String { "Title, author or ISBN" }

    public func search(_ query: MetadataQuery, limit: Int) async throws -> [MetadataCandidate] {
        try await client.search(query, limit: limit)
    }

    public func details(for candidate: MetadataCandidate) async throws -> MetadataDetails {
        // OpenLibrary's search response already carries everything the tag diff
        // needs, so a second round trip would buy nothing. Books have no
        // chapters here: an EPUB's table of contents is the file's own.
        MetadataDetails(book: try await client.book(key: candidate.id), chapters: [])
    }
}

/// Every provider the app knows about, in the order the wizard offers them.
public enum MetadataProviders {
    public static func all(region: AudibleRegion = .unitedKingdom) -> [any MetadataProvider] {
        [AudibleMetadataProvider(region: region), OpenLibraryProvider()]
    }

    public static func serving(_ kind: MediaKind, region: AudibleRegion = .unitedKingdom) -> [any MetadataProvider] {
        all(region: region).filter { $0.kinds.contains(kind) }
    }
}
