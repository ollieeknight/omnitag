import Foundation
import MediaCore

public struct OpenLibraryClient: Sendable {
    private let transport: any HTTPTransporting

    public init(transport: any HTTPTransporting = URLSessionTransport()) {
        self.transport = transport
    }

    public func search(_ query: AudiobookQuery, limit: Int = 20) async throws -> [AudiobookCandidate] {
        guard !query.isEmpty, !query.searchTerms.isEmpty else { throw MetadataError.emptyQuery }

        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query.searchTerms),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: "key,title,author_name,first_publish_year,cover_i,publisher,isbn")
        ]

        guard let url = components.url else { throw MetadataError.malformedResponse("bad URL") }
        let (data, status) = try await transport.data(from: url)
        guard (200..<300).contains(status) else { throw MetadataError.server(status: status) }

        do {
            let response = try JSONDecoder().decode(SearchResponse.self, from: data)
            return response.docs.map(\.candidate)
        } catch {
            throw MetadataError.malformedResponse(error.localizedDescription)
        }
    }

    public func book(key: String) async throws -> AudiobookBook {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "q", value: key),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fields", value: "key,title,author_name,first_publish_year,cover_i,publisher,isbn,subject")
        ]

        guard let url = components.url else { throw MetadataError.malformedResponse("bad URL") }
        let (data, status) = try await transport.data(from: url)
        guard (200..<300).contains(status) else { throw MetadataError.server(status: status) }

        do {
            let response = try JSONDecoder().decode(SearchResponse.self, from: data)
            guard let doc = response.docs.first else {
                throw MetadataError.notAvailable(region: "openlibrary")
            }
            return doc.book
        } catch {
            throw MetadataError.malformedResponse(error.localizedDescription)
        }
    }

    // MARK: wire format
    private struct SearchResponse: Decodable {
        var docs: [Doc]
    }

    private struct Doc: Decodable {
        var key: String
        var title: String
        var author_name: [String]?
        var first_publish_year: Int?
        var cover_i: Int?
        var publisher: [String]?
        var subject: [String]?

        var artworkURL: URL? {
            cover_i.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") }
        }

        var candidate: AudiobookCandidate {
            AudiobookCandidate(
                asin: key,
                title: title,
                subtitle: nil,
                authors: author_name ?? [],
                narrators: [],
                publisher: publisher?.first,
                year: first_publish_year,
                runtimeMinutes: nil,
                series: nil,
                seriesIndex: nil,
                summary: nil,
                artworkURL: artworkURL
            )
        }

        var book: AudiobookBook {
            AudiobookBook(
                asin: key,
                title: title,
                subtitle: nil,
                authors: author_name ?? [],
                narrators: [],
                publisher: publisher?.first,
                year: first_publish_year,
                language: nil,
                summary: nil,
                genres: subject ?? [],
                series: nil,
                seriesIndex: nil,
                runtimeMinutes: nil,
                artworkURL: artworkURL
            )
        }
    }
}
