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

    /// `kind` matters only to a provider serving more than one — TMDB routes
    /// `/search/movie` vs `/search/tv` by it. A single-kind provider ignores
    /// it via the default overload below.
    func search(_ query: MetadataQuery, kind: MediaKind, limit: Int) async throws -> [MetadataCandidate]
    func details(for candidate: MetadataCandidate, kind: MediaKind) async throws -> MetadataDetails

    /// True when a search candidate from this provider names a group (a TV
    /// show) rather than the exact thing that gets tagged (an episode) — the
    /// wizard needs an extra picker step before it has anything to diff. Only
    /// TMDB's TV half needs this; everything else defaults to `false`. A
    /// property rather than `provider is TMDBProvider` so the wizard's
    /// routing decision is testable against a fake provider, not tied to one
    /// concrete type.
    var hasEpisodePicker: Bool { get }

    /// True when this provider needs an API key and does not have one, so the
    /// wizard can say so before the user types a query that is certain to
    /// fail. Only TMDB needs a key; everything else defaults to `false`.
    var isMissingAPIKey: Bool { get }
}

public extension MetadataProvider {
    func search(_ query: MetadataQuery, limit: Int) async throws -> [MetadataCandidate] {
        try await search(query, kind: kinds.first ?? .movie, limit: limit)
    }

    func details(for candidate: MetadataCandidate) async throws -> MetadataDetails {
        try await details(for: candidate, kind: kinds.first ?? .movie)
    }

    var hasEpisodePicker: Bool {
        false
    }

    var isMissingAPIKey: Bool {
        false
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
        service = transport.map { AudibleProvider(region: region, transport: $0) }
            ?? AudibleProvider(region: region)
    }

    public var id: String {
        "audible.\(region.rawValue)"
    }

    public var name: String {
        "Audible \(region.rawValue.uppercased())"
    }

    public var kinds: Set<MediaKind> {
        [.audiobook]
    }

    public var searchHint: String {
        "Title, author, ASIN or Audible link"
    }

    public func search(_ query: MetadataQuery, kind: MediaKind, limit: Int) async throws -> [MetadataCandidate] {
        try await service.search(query, limit: limit)
    }

    public func details(for candidate: MetadataCandidate, kind: MediaKind) async throws -> MetadataDetails {
        try await service.details(for: candidate.id)
    }
}

/// OpenLibrary: no key, no storefronts, and the only free catalogue that covers
/// print books rather than audio editions.
public struct OpenLibraryProvider: MetadataProvider {
    private let client: OpenLibraryClient

    public init(transport: (any HTTPTransporting)? = nil) {
        client = transport.map { OpenLibraryClient(transport: $0) } ?? OpenLibraryClient()
    }

    public var id: String {
        "openlibrary"
    }

    public var name: String {
        "OpenLibrary"
    }

    public var kinds: Set<MediaKind> {
        [.book]
    }

    public var searchHint: String {
        "Title, author or ISBN"
    }

    public func search(_ query: MetadataQuery, kind: MediaKind, limit: Int) async throws -> [MetadataCandidate] {
        try await client.search(query, limit: limit)
    }

    public func details(for candidate: MetadataCandidate, kind: MediaKind) async throws -> MetadataDetails {
        // OpenLibrary's search response already carries everything the tag diff
        // needs, so a second round trip would buy nothing. Books have no
        // chapters here: an EPUB's table of contents is the file's own.
        try await MetadataDetails(book: client.book(key: candidate.id), chapters: [])
    }
}

/// Every provider the app knows about, in the order the wizard offers them.
public enum MetadataProviders {
    public static func serving(_ kind: MediaKind, region: AudibleRegion = .unitedKingdom) -> [any MetadataProvider] {
        [AudibleMetadataProvider(region: region), OpenLibraryProvider(), TMDBProvider(), ITunesProvider()]
            .filter { $0.kinds.contains(kind) }
    }
}
