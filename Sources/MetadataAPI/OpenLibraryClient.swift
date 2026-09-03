import Foundation
import MediaCore

public struct OpenLibraryClient: Sendable {
    private let transport: any HTTPTransporting

    public init(transport: any HTTPTransporting = URLSessionTransport()) {
        self.transport = transport
    }

    public func search(_ query: MetadataQuery, limit: Int = 20) async throws -> [MetadataCandidate] {
        guard !query.isEmpty, !query.searchTerms.isEmpty else { throw MetadataError.emptyQuery }

        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query.searchTerms),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: "key,title,subtitle,author_name,first_publish_year,cover_i,publisher,isbn,subject,language,series")
        ]

        guard let url = components.url else { throw MetadataError.malformedResponse("bad URL") }
        let (data, status) = try await transport.data(from: url)
        guard (200 ..< 300).contains(status) else { throw MetadataError.server(status: status) }

        do {
            let response = try JSONDecoder().decode(SearchResponse.self, from: data)
            return response.docs.map(\.candidate)
        } catch {
            throw MetadataError.malformedResponse(error.localizedDescription)
        }
    }

    public func book(key: String) async throws -> MetadataRecord {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "q", value: key),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fields", value: "key,title,subtitle,author_name,first_publish_year,cover_i,publisher,isbn,subject,language,series")
        ]

        guard let url = components.url else { throw MetadataError.malformedResponse("bad URL") }
        let (data, status) = try await transport.data(from: url)
        guard (200 ..< 300).contains(status) else { throw MetadataError.server(status: status) }

        do {
            let response = try JSONDecoder().decode(SearchResponse.self, from: data)
            guard let doc = response.docs.first else {
                throw MetadataError.notAvailable(region: "openlibrary")
            }

            var description: String?
            if key.hasPrefix("/works/"), let workUrl = URL(string: "https://openlibrary.org\(key).json") {
                if let (workData, workStatus) = try? await transport.data(from: workUrl), (200 ..< 300).contains(workStatus) {
                    description = try? JSONDecoder().decode(WorkDetail.self, from: workData).descriptionText
                }
            }

            var record = doc.book
            if let description {
                record.summary = description
            }
            return record
        } catch {
            throw MetadataError.malformedResponse(error.localizedDescription)
        }
    }

    // MARK: wire format

    private struct WorkDetail: Decodable {
        private struct Wrapped: Decodable { var value: String }

        var descriptionText: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let str = try? container.decode(String.self, forKey: .description) {
                descriptionText = str
            } else if let wrapped = try? container.decode(Wrapped.self, forKey: .description) {
                descriptionText = wrapped.value
            }
        }

        private enum CodingKeys: String, CodingKey {
            case description
        }
    }

    private struct SearchResponse: Decodable {
        var docs: [Doc]
    }

    private struct Doc: Decodable {
        var key: String
        var title: String
        var subtitle: String?
        var author_name: [String]?
        var first_publish_year: Int?
        var cover_i: Int?
        var publisher: [String]?
        var subject: [String]?
        var isbn: [String]?
        var language: [String]?
        var series: [String]?

        var artworkURL: URL? {
            cover_i.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") }
        }

        /// An ISBN identifies an *edition*; an OpenLibrary search returns a
        /// *work*. The Laura Palmer work lists sixteen ISBNs across six
        /// publishers, and picking one would be inventing a fact — so a
        /// suggestion is only offered when the work is unambiguous.
        var unambiguousISBN: String? {
            let thirteens = Set((isbn ?? []).filter { $0.count == 13 })
            return thirteens.count == 1 ? thirteens.first : nil
        }

        var candidate: MetadataCandidate {
            MetadataCandidate(
                id: key,
                title: title,
                subtitle: subtitle,
                authors: author_name ?? [],
                narrators: [],
                publisher: publisher?.first,
                year: first_publish_year,
                runtimeMinutes: nil,
                series: series?.first,
                seriesIndex: nil,
                summary: nil,
                artworkURL: artworkURL
            )
        }

        var book: MetadataRecord {
            MetadataRecord(
                id: key,
                title: title,
                subtitle: subtitle,
                authors: author_name ?? [],
                narrators: [],
                publisher: publisher?.first,
                year: first_publish_year,
                language: language?.first,
                summary: nil,
                genres: subject ?? [],
                series: series?.first,
                seriesIndex: nil,
                runtimeMinutes: nil,
                artworkURL: artworkURL,
                asin: nil,
                isbn: unambiguousISBN,
                kind: .book
            )
        }
    }
}
