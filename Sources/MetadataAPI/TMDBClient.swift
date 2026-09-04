import Foundation
import MediaCore

/// The Movie Database: search and detail for movies and TV shows/episodes.
/// The only OmniTag provider that needs a key — see `TMDBKeyStore` and
/// `docs/MOVIES_TV.md`. `apiKey` is checked before any request is made, so a
/// missing key never costs a round trip.
public struct TMDBClient: Sendable {
    private let apiKey: String?
    private let transport: any HTTPTransporting

    public init(apiKey: String?, transport: any HTTPTransporting = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let apiKey, !apiKey.isEmpty else { throw MetadataError.missingAPIKey(provider: "TMDB") }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.themoviedb.org"
        components.path = "/3/\(path)"
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + query
        guard let url = components.url else { throw MetadataError.malformedResponse("bad URL") }
        return url
    }

    private struct APIError: Decodable { var statusMessage: String }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let (data, status) = try await transport.data(from: url(path, query: query))
        guard (200 ..< 300).contains(status) else {
            let message = try? JSONDecoder.api.decode(APIError.self, from: data).statusMessage
            throw MetadataError.server(status: status, message: message)
        }
        do {
            return try JSONDecoder.api.decode(T.self, from: data)
        } catch {
            throw MetadataError.malformedResponse(error.localizedDescription)
        }
    }

    // MARK: search

    public func searchMovies(_ query: MetadataQuery, limit: Int = 20) async throws -> [MetadataCandidate] {
        guard !query.isEmpty, !query.searchTerms.isEmpty else { throw MetadataError.emptyQuery }
        let response = try await get(
            "search/movie", query: [URLQueryItem(name: "query", value: query.searchTerms)],
            as: MovieSearchResponse.self
        )
        return Array(response.results.prefix(limit)).map(\.candidate)
    }

    public func searchTV(_ query: MetadataQuery, limit: Int = 20) async throws -> [MetadataCandidate] {
        guard !query.isEmpty, !query.searchTerms.isEmpty else { throw MetadataError.emptyQuery }
        let response = try await get(
            "search/tv", query: [URLQueryItem(name: "query", value: query.searchTerms)],
            as: TVSearchResponse.self
        )
        return Array(response.results.prefix(limit)).map(\.candidate)
    }

    // MARK: detail

    public func movieDetails(id: String) async throws -> MetadataRecord {
        let movie = try await get(
            "movie/\(id)", query: [URLQueryItem(name: "append_to_response", value: "credits,release_dates")],
            as: MovieDetail.self
        )
        return movie.record
    }

    /// The show itself — no episode chosen yet. `episodeDetails` fills in
    /// season/episode once the wizard's episode-picker step has one.
    public func tvShowDetails(id: String) async throws -> MetadataRecord {
        let show = try await get("tv/\(id)", as: TVShowDetail.self)
        return show.record
    }

    public func seasonEpisodes(showID: String, season: Int) async throws -> [EpisodeSummary] {
        let response = try await get("tv/\(showID)/season/\(season)", as: SeasonDetail.self)
        return response.episodes.map { EpisodeSummary(number: $0.episodeNumber, title: $0.name, airDate: $0.airDate) }
    }

    public func episodeDetails(showID: String, showName: String, season: Int, episode: Int) async throws -> MetadataRecord {
        let detail = try await get(
            "tv/\(showID)/season/\(season)/episode/\(episode)",
            query: [URLQueryItem(name: "append_to_response", value: "credits")], as: EpisodeDetail.self
        )
        return detail.record(showID: showID, showName: showName)
    }

    public struct EpisodeSummary: Sendable, Identifiable, Equatable {
        public var number: Int
        public var title: String
        public var airDate: String?
        public var id: Int {
            number
        }
    }

    // MARK: wire format

    private struct MovieSearchResponse: Decodable { var results: [MovieSummary] }
    private struct TVSearchResponse: Decodable { var results: [TVSummary] }

    private struct MovieSummary: Decodable {
        var id: Int
        var title: String
        var releaseDate: String?
        var overview: String?
        var posterPath: String?

        var candidate: MetadataCandidate {
            MetadataCandidate(
                id: String(id), title: title, subtitle: nil, authors: [], narrators: [],
                publisher: nil, year: releaseDate.flatMap { Int($0.prefix(4)) }, runtimeMinutes: nil,
                series: nil, seriesIndex: nil, summary: overview, artworkURL: TMDBImage.url(posterPath)
            )
        }
    }

    private struct TVSummary: Decodable {
        var id: Int
        var name: String
        var firstAirDate: String?
        var overview: String?
        var posterPath: String?

        var candidate: MetadataCandidate {
            MetadataCandidate(
                id: String(id), title: name, subtitle: nil, authors: [], narrators: [],
                publisher: nil, year: firstAirDate.flatMap { Int($0.prefix(4)) }, runtimeMinutes: nil,
                series: nil, seriesIndex: nil, summary: overview, artworkURL: TMDBImage.url(posterPath)
            )
        }
    }

    private struct MovieDetail: Decodable {
        struct Genre: Decodable { var name: String }
        struct Company: Decodable { var name: String }
        struct CrewMember: Decodable { var job: String
            var name: String
        }

        struct Credits: Decodable { var crew: [CrewMember] }
        struct ReleaseDate: Decodable { var certification: String }
        struct CountryRelease: Decodable { var iso31661: String
            var releaseDates: [ReleaseDate]
        }

        struct ReleaseDatesWrapper: Decodable { var results: [CountryRelease] }

        var id: Int
        var title: String
        var releaseDate: String?
        var overview: String?
        var posterPath: String?
        var genres: [Genre]?
        var productionCompanies: [Company]?
        var credits: Credits?
        var releaseDates: ReleaseDatesWrapper?

        var record: MetadataRecord {
            MetadataRecord(
                id: String(id), title: title, year: releaseDate.flatMap { Int($0.prefix(4)) },
                summary: overview, genres: genres?.map(\.name) ?? [],
                artworkURL: TMDBImage.url(posterPath),
                director: credits?.crew.first { $0.job == "Director" }?.name,
                studio: productionCompanies?.first?.name,
                contentRating: releaseDates?.results.first { $0.iso31661 == "US" }?.releaseDates.first?.certification,
                tmdbID: String(id), kind: .movie
            )
        }
    }

    private struct TVShowDetail: Decodable {
        struct Genre: Decodable { var name: String }

        var id: Int
        var name: String
        var firstAirDate: String?
        var overview: String?
        var posterPath: String?
        var genres: [Genre]?

        var record: MetadataRecord {
            MetadataRecord(
                id: String(id), title: name, year: firstAirDate.flatMap { Int($0.prefix(4)) },
                summary: overview, genres: genres?.map(\.name) ?? [],
                artworkURL: TMDBImage.url(posterPath), tmdbID: String(id), kind: .tvEpisode
            )
        }
    }

    private struct SeasonDetail: Decodable {
        struct Episode: Decodable { var episodeNumber: Int
            var name: String
            var airDate: String?
        }

        var episodes: [Episode]
    }

    private struct EpisodeDetail: Decodable {
        struct CrewMember: Decodable { var job: String
            var name: String
        }

        var id: Int
        var name: String
        var overview: String?
        var seasonNumber: Int
        var episodeNumber: Int
        var airDate: String?
        var crew: [CrewMember]?

        /// `tmdbID` is the episode's own id, not the show's — every episode of a
        /// season would otherwise write the same id, and a later "refresh
        /// metadata" from the tag could never tell them apart.
        ///
        /// `title` is the episode's own name, with the show in `showName`.
        /// A "Show — Episode" composite reads doubled in every player that
        /// shows the series alongside the title (Plex, Infuse, Apple TV).
        func record(showID: String, showName: String) -> MetadataRecord {
            MetadataRecord(
                id: showID, title: name, year: airDate.flatMap { Int($0.prefix(4)) },
                summary: overview, director: crew?.first { $0.job == "Director" }?.name,
                showName: showName, seasonNumber: seasonNumber, episodeNumber: episodeNumber,
                episodeTitle: name, tmdbID: String(id), kind: .tvEpisode
            )
        }
    }
}

/// TMDB serves images from a CDN keyed by path, not URL — `w780` is a good
/// balance for a cover well; `CoverImage` resamples on import regardless.
enum TMDBImage {
    static func url(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w780\(path)")
    }
}
