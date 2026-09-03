import Foundation
import MediaCore

/// TMDB behind `MetadataProvider`: one type for both movies and TV, routed by
/// `kind` since the underlying API is two endpoints per operation. See
/// `docs/MOVIES_TV.md` for why one type rather than two, and why `/search/multi`
/// was rejected.
///
/// A TV search candidate names a *show*; `details(for:kind:)` on a TV
/// candidate returns the show-level record, with no episode chosen. Picking
/// an episode is the wizard's `.episode` step, which calls `episodeDetails`
/// directly rather than through this protocol method — there is no
/// `MetadataCandidate` for "season 1, episode 1" to route through.
public struct TMDBProvider: MetadataProvider {
    private let keyStore: TMDBKeyStore
    private let transport: any HTTPTransporting

    public init(keyStore: TMDBKeyStore = TMDBKeyStore(), transport: (any HTTPTransporting)? = nil) {
        self.keyStore = keyStore
        self.transport = transport ?? URLSessionTransport()
    }

    public var id: String {
        "tmdb"
    }

    public var name: String {
        "TMDB"
    }

    public var kinds: Set<MediaKind> {
        [.movie, .tvEpisode]
    }

    public var searchHint: String {
        "Title"
    }

    public var hasEpisodePicker: Bool {
        true
    }

    private var client: TMDBClient {
        TMDBClient(apiKey: keyStore.key(), transport: transport)
    }

    public func search(_ query: MetadataQuery, kind: MediaKind, limit: Int) async throws -> [MetadataCandidate] {
        switch kind {
        case .tvEpisode: try await client.searchTV(query, limit: limit)
        default: try await client.searchMovies(query, limit: limit)
        }
    }

    public func details(for candidate: MetadataCandidate, kind: MediaKind) async throws -> MetadataDetails {
        let record = switch kind {
        case .tvEpisode: try await client.tvShowDetails(id: candidate.id)
        default: try await client.movieDetails(id: candidate.id)
        }
        return MetadataDetails(book: record, chapters: [])
    }

    /// The wizard's episode-picker step calls this directly once a season and
    /// episode number are chosen — see `docs/MOVIES_TV.md`.
    public func episodeDetails(showID: String, showName: String, season: Int, episode: Int) async throws -> MetadataDetails {
        try await MetadataDetails(book: client.episodeDetails(showID: showID, showName: showName, season: season, episode: episode), chapters: [])
    }

    public func seasonEpisodes(showID: String, season: Int) async throws -> [TMDBClient.EpisodeSummary] {
        try await client.seasonEpisodes(showID: showID, season: season)
    }
}
