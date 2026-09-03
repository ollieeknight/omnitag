import Foundation
@testable import MetadataAPI
import Testing

@Suite("TMDBClient")
struct TMDBClientTests {
    private func client(status: Int = 200) -> (TMDBClient, StubTransport) {
        let transport = StubTransport()
        transport.status = status
        return (TMDBClient(apiKey: "test-key", transport: transport), transport)
    }

    private static let movieSearchJSON = """
    {"results":[{"id":603,"title":"The Matrix","release_date":"1999-03-30",
    "overview":"A hacker learns the truth.","poster_path":"/matrix.jpg","genre_ids":[28,878]}]}
    """

    private static let movieDetailJSON = """
    {"id":603,"title":"The Matrix","release_date":"1999-03-30",
    "overview":"A hacker learns the truth.","poster_path":"/matrix.jpg",
    "genres":[{"id":28,"name":"Action"},{"id":878,"name":"Science Fiction"}],
    "production_companies":[{"id":79,"name":"Village Roadshow Pictures"}],
    "credits":{"crew":[{"job":"Director","name":"Lana Wachowski"},{"job":"Producer","name":"Joel Silver"}]},
    "release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"R"}]}]}}
    """

    private static let tvSearchJSON = """
    {"results":[{"id":1622,"name":"Twin Peaks","first_air_date":"1990-04-08",
    "overview":"A murder investigation.","poster_path":"/tp.jpg"}]}
    """

    private static let tvDetailJSON = """
    {"id":1622,"name":"Twin Peaks","first_air_date":"1990-04-08",
    "overview":"A murder investigation.","poster_path":"/tp.jpg",
    "genres":[{"id":9648,"name":"Mystery"}],
    "number_of_seasons":3}
    """

    private static let episodeJSON = """
    {"id":38713,"name":"Pilot","overview":"Laura Palmer is found dead.",
    "season_number":1,"episode_number":1,"air_date":"1990-04-08",
    "crew":[{"job":"Director","name":"David Lynch"}]}
    """

    // MARK: movies

    @Test("movie search returns candidates keyed by TMDB id")
    func movieSearch() async throws {
        let (client, transport) = client()
        transport.responses["search/movie"] = Data(Self.movieSearchJSON.utf8)

        let results = try await client.searchMovies(.init(title: "The Matrix"), limit: 20)
        let candidate = try #require(results.first)
        #expect(candidate.id == "603")
        #expect(candidate.title == "The Matrix")
        #expect(candidate.year == 1999)
        #expect(candidate.artworkURL?.absoluteString.contains("matrix.jpg") == true)
    }

    @Test("movie detail fills director, studio and content rating")
    func movieDetail() async throws {
        let (client, transport) = client()
        transport.responses["movie/603"] = Data(Self.movieDetailJSON.utf8)

        let record = try await client.movieDetails(id: "603")
        #expect(record.title == "The Matrix")
        #expect(record.director == "Lana Wachowski")
        #expect(record.studio == "Village Roadshow Pictures")
        #expect(record.contentRating == "R")
        #expect(record.genres == ["Action", "Science Fiction"])
        #expect(record.tmdbID == "603")
    }

    // MARK: TV

    @Test("TV search returns show candidates")
    func tvSearch() async throws {
        let (client, transport) = client()
        transport.responses["search/tv"] = Data(Self.tvSearchJSON.utf8)

        let results = try await client.searchTV(.init(title: "Twin Peaks"), limit: 20)
        let candidate = try #require(results.first)
        #expect(candidate.id == "1622")
        #expect(candidate.title == "Twin Peaks")
        #expect(candidate.year == 1990)
    }

    @Test("show detail is the show, not an episode")
    func tvShowDetail() async throws {
        let (client, transport) = client()
        transport.responses["tv/1622"] = Data(Self.tvDetailJSON.utf8)

        let record = try await client.tvShowDetails(id: "1622")
        #expect(record.title == "Twin Peaks")
        #expect(record.tmdbID == "1622")
        // No episode has been picked yet.
        #expect(record.episodeNumber == nil)
        #expect(record.seasonNumber == nil)
    }

    @Test("episode detail fills show name, season and episode number")
    func episodeDetail() async throws {
        let (client, transport) = client()
        transport.responses["tv/1622/season/1/episode/1"] = Data(Self.episodeJSON.utf8)

        let record = try await client.episodeDetails(showID: "1622", showName: "Twin Peaks", season: 1, episode: 1)
        #expect(record.showName == "Twin Peaks")
        #expect(record.episodeTitle == "Pilot")
        #expect(record.seasonNumber == 1)
        #expect(record.episodeNumber == 1)
        #expect(record.director == "David Lynch")
        #expect(record.year == 1990)
        // Every episode of a show must carry its own TMDB id, not the show's —
        // otherwise a later "refresh metadata" from the tag cannot tell episodes apart.
        #expect(record.tmdbID == "38713")
    }

    // MARK: errors

    @Test("no API key throws before any request is made")
    func missingKey() async throws {
        let transport = StubTransport()
        let client = TMDBClient(apiKey: nil, transport: transport)
        await #expect(throws: MetadataError.missingAPIKey(provider: "TMDB")) {
            _ = try await client.searchMovies(.init(title: "The Matrix"), limit: 20)
        }
        #expect(transport.requestedURLs.isEmpty)
    }

    @Test("a non-200 status becomes a server error")
    func serverError() async throws {
        let (client, transport) = client(status: 401)
        transport.responses["search/movie"] = Data(Self.movieSearchJSON.utf8)
        await #expect(throws: MetadataError.server(status: 401)) {
            _ = try await client.searchMovies(.init(title: "The Matrix"), limit: 20)
        }
    }

    @Test("a non-200 status carries TMDB's own error message when the body has one")
    func serverErrorCarriesTMDBMessage() async throws {
        let (client, transport) = client(status: 401)
        transport.responses["search/movie"] = Data(
            #"{"status_code":7,"status_message":"Invalid API key: You must be granted a valid key."}"#.utf8
        )
        await #expect(throws: MetadataError.server(
            status: 401, message: "Invalid API key: You must be granted a valid key."
        )) {
            _ = try await client.searchMovies(.init(title: "The Matrix"), limit: 20)
        }
    }

    @Test("malformed JSON is reported, not crashed on")
    func malformedResponse() async throws {
        let (client, transport) = client()
        transport.responses["search/movie"] = Data("not json".utf8)
        await #expect(throws: MetadataError.self) {
            _ = try await client.searchMovies(.init(title: "The Matrix"), limit: 20)
        }
    }
}
