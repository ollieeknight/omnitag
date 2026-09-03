import Foundation
import MediaCore
@testable import MetadataAPI
import Testing

@Suite("TMDBProvider")
struct TMDBProviderTests {
    private static let movieSearchJSON = Data("""
    {"results":[{"id":603,"title":"The Matrix","release_date":"1999-03-30","overview":"A hacker.","poster_path":"/m.jpg"}]}
    """.utf8)

    private static let movieDetailJSON = Data("""
    {"id":603,"title":"The Matrix","release_date":"1999-03-30","overview":"A hacker.","poster_path":"/m.jpg"}
    """.utf8)

    private static let tvSearchJSON = Data("""
    {"results":[{"id":1622,"name":"Twin Peaks","first_air_date":"1990-04-08","overview":"A murder.","poster_path":"/tp.jpg"}]}
    """.utf8)

    private static let tvDetailJSON = Data("""
    {"id":1622,"name":"Twin Peaks","first_air_date":"1990-04-08","overview":"A murder.","poster_path":"/tp.jpg"}
    """.utf8)

    private func provider(key: String? = "test-key") -> (TMDBProvider, StubTransport) {
        let store = TMDBKeyStore(service: "omnitag.tmdb.test.\(UUID().uuidString)")
        if let key {
            store.save(key: key)
        }
        let transport = StubTransport()
        return (TMDBProvider(keyStore: store, transport: transport), transport)
    }

    @Test("a movie-kind query searches /search/movie")
    func routesMovieSearch() async throws {
        let (provider, transport) = provider()
        transport.responses["search/movie"] = Self.movieSearchJSON

        let results = try await provider.search(.init(title: "The Matrix"), kind: .movie, limit: 20)
        #expect(results.first?.title == "The Matrix")
        #expect(transport.requestedURLs.contains { $0.absoluteString.contains("search/movie") })
    }

    @Test("a tvEpisode-kind query searches /search/tv")
    func routesTVSearch() async throws {
        let (provider, transport) = provider()
        transport.responses["search/tv"] = Self.tvSearchJSON

        let results = try await provider.search(.init(title: "Twin Peaks"), kind: .tvEpisode, limit: 20)
        #expect(results.first?.title == "Twin Peaks")
        #expect(transport.requestedURLs.contains { $0.absoluteString.contains("search/tv") })
    }

    @Test("details for a movie candidate fetches the movie")
    func movieDetails() async throws {
        let (provider, transport) = provider()
        transport.responses["search/movie"] = Self.movieSearchJSON
        transport.responses["movie/603"] = Self.movieDetailJSON

        let candidate = try #require(try await provider.search(.init(title: "The Matrix"), kind: .movie, limit: 20).first)
        let details = try await provider.details(for: candidate, kind: .movie)
        #expect(details.book.title == "The Matrix")
        #expect(details.chapters.isEmpty)
    }

    @Test("details for a TV candidate returns the show, with no episode picked yet")
    func tvDetailsReturnsShow() async throws {
        let (provider, transport) = provider()
        transport.responses["search/tv"] = Self.tvSearchJSON
        transport.responses["tv/1622"] = Self.tvDetailJSON

        let candidate = try #require(try await provider.search(.init(title: "Twin Peaks"), kind: .tvEpisode, limit: 20).first)
        let details = try await provider.details(for: candidate, kind: .tvEpisode)
        #expect(details.book.title == "Twin Peaks")
        #expect(details.book.episodeNumber == nil, "no episode chosen yet")
    }

    @Test("no key configured produces a clear error, not a network failure")
    func missingKeyIsClear() async throws {
        let (provider, _) = provider(key: nil)
        await #expect(throws: MetadataError.missingAPIKey(provider: "TMDB")) {
            _ = try await provider.search(.init(title: "The Matrix"), kind: .movie, limit: 20)
        }
    }
}
