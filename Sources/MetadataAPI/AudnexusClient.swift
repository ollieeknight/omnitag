import Foundation
import MediaCore

/// Audnexus: a free, unauthenticated mirror of Audible's product data, keyed by
/// ASIN. It is the only source of **chapters** without an Audible login, which
/// is the whole reason it is here.
public struct AudnexusClient: Sendable {
    private let region: AudibleRegion
    private let transport: any HTTPTransporting

    public init(region: AudibleRegion = .unitedKingdom, transport: any HTTPTransporting = URLSessionTransport()) {
        self.region = region
        self.transport = transport
    }

    private func url(_ path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.audnex.us"
        components.path = path
        components.queryItems = [URLQueryItem(name: "region", value: region.rawValue)]
        guard let url = components.url else { throw MetadataError.malformedResponse("bad URL") }
        return url
    }

    public func book(asin: String) async throws -> MetadataRecord {
        let (data, status) = try await transport.data(from: url("/books/\(asin)"))
        guard (200 ..< 300).contains(status) else { throw MetadataError.server(status: status) }
        if let failure = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            throw failure.error.code == "REGION_UNAVAILABLE"
                ? MetadataError.notAvailable(region: region.rawValue)
                : MetadataError.malformedResponse(failure.error.code)
        }
        do {
            return try JSONDecoder.api.decode(Book.self, from: data).book
        } catch {
            throw MetadataError.malformedResponse(error.localizedDescription)
        }
    }

    public func chapters(asin: String) async throws -> [Chapter] {
        let (data, status) = try await transport.data(from: url("/books/\(asin)/chapters"))
        guard (200 ..< 300).contains(status) else { throw MetadataError.server(status: status) }
        do {
            return try JSONDecoder.api.decode(ChapterResponse.self, from: data).chapters
                .enumerated()
                .map { index, chapter in
                    Chapter(
                        index: index,
                        start: Double(chapter.startOffsetMs) / 1000,
                        duration: Double(chapter.lengthMs) / 1000,
                        title: chapter.title
                    )
                }
        } catch {
            throw MetadataError.malformedResponse(error.localizedDescription)
        }
    }

    // MARK: wire format

    private struct ErrorResponse: Decodable {
        struct Failure: Decodable { var code: String }
        var error: Failure
    }

    private struct ChapterResponse: Decodable {
        struct Entry: Decodable {
            var lengthMs: Int
            var startOffsetMs: Int
            var title: String
        }

        var chapters: [Entry]
    }

    private struct Book: Decodable {
        struct Person: Decodable { var name: String }
        struct Genre: Decodable { var name: String
            var type: String
        }

        struct Series: Decodable { var name: String?
            var position: String?
        }

        var asin: String
        var title: String
        var subtitle: String?
        var authors: [Person]?
        var narrators: [Person]?
        var publisherName: String?
        var releaseDate: String?
        var language: String?
        var summary: String?
        var description: String?
        var genres: [Genre]?
        var seriesPrimary: Series?
        var runtimeLengthMin: Int?
        var image: String?
        var isbn: String?

        var book: MetadataRecord {
            let filteredGenres = genres?.filter { $0.type == "genre" }.map(\.name) ?? []
            let effectiveGenres = filteredGenres.isEmpty ? (genres?.map(\.name) ?? []) : filteredGenres

            return MetadataRecord(
                id: asin, title: title, subtitle: subtitle,
                authors: authors?.map(\.name) ?? [],
                narrators: narrators?.map(\.name) ?? [],
                publisher: publisherName,
                year: releaseDate.flatMap { Int($0.prefix(4)) },
                language: language,
                summary: (description ?? summary).map(Self.strippingHTML),
                genres: effectiveGenres,
                series: seriesPrimary?.name,
                seriesIndex: seriesPrimary?.position.flatMap { Int($0) },
                runtimeMinutes: runtimeLengthMin,
                artworkURL: image.flatMap { URL(string: $0) },
                asin: asin,
                isbn: (isbn?.isEmpty == true) ? nil : isbn,
                kind: .audiobook
            )
        }

        static func strippingHTML(_ html: String) -> String {
            html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Audible for search, Audnexus for detail and chapters — the split the two
/// APIs force, hidden behind one call each.
///
/// Storefronts are not mirrors of each other: the developer's own Laura Palmer
/// audiobook does not exist in the UK catalogue at all. So the chosen region is
/// tried first and the US is tried second, and the result says which storefront
/// actually answered.
public struct AudibleProvider: Sendable {
    public struct SearchOutcome: Sendable {
        public var candidates: [MetadataCandidate]
        /// The storefront that produced these results — not always the one asked for.
        public var region: AudibleRegion
    }

    public let region: AudibleRegion
    private let transport: any HTTPTransporting

    public init(region: AudibleRegion = .unitedKingdom, transport: any HTTPTransporting = URLSessionTransport()) {
        self.region = region
        self.transport = transport
    }

    private var fallbackRegions: [AudibleRegion] {
        region == .unitedStates ? [region] : [region, .unitedStates]
    }

    public func search(_ query: MetadataQuery, limit: Int = 20) async throws -> [MetadataCandidate] {
        try await searchWithRegion(query, limit: limit).candidates
    }

    public func searchWithRegion(_ query: MetadataQuery, limit: Int = 20) async throws -> SearchOutcome {
        var lastError: (any Error)?

        // Region first, then each rung of the query ladder: a narrower search
        // that finds nothing is worse than a broad one ranked properly.
        for candidateRegion in fallbackRegions {
            let client = AudibleClient(region: candidateRegion, transport: transport)
            for rung in query.searchLadder.isEmpty ? [""] : query.searchLadder {
                var attempt = query
                attempt.keywords = query.asin == nil ? rung : nil
                attempt.title = nil
                attempt.author = nil
                attempt.narrator = nil
                do {
                    let results = try await client.search(attempt, limit: limit)
                    if !results.isEmpty {
                        return SearchOutcome(
                            candidates: results.sorted { query.score($0) > query.score($1) },
                            region: candidateRegion
                        )
                    }
                } catch MetadataError.emptyQuery {
                    throw MetadataError.emptyQuery
                } catch {
                    lastError = error
                }
            }
        }

        // OpenLibrary fallback
        let openLibrary = OpenLibraryClient(transport: transport)
        for rung in query.searchLadder.isEmpty ? [""] : query.searchLadder {
            var attempt = query
            attempt.keywords = query.asin == nil ? rung : nil
            attempt.title = nil
            attempt.author = nil
            attempt.narrator = nil
            do {
                let results = try await openLibrary.search(attempt, limit: limit)
                if !results.isEmpty {
                    return SearchOutcome(
                        candidates: results.sorted { query.score($0) > query.score($1) },
                        region: region
                    )
                }
            } catch MetadataError.emptyQuery {
                throw MetadataError.emptyQuery
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        return SearchOutcome(candidates: [], region: region)
    }

    /// Chapters are best-effort: plenty of books have none, and a missing list
    /// must not cost the user the tags they came for.
    public func details(for asin: String, in preferredRegion: AudibleRegion? = nil) async throws -> MetadataDetails {
        if asin.starts(with: "/works/") {
            let client = OpenLibraryClient(transport: transport)
            let book = try await client.book(key: asin)
            return MetadataDetails(book: book, chapters: [])
        }

        let regions = preferredRegion.map { $0 == .unitedStates ? [$0] : [$0, .unitedStates] }
            ?? fallbackRegions
        var lastError: (any Error)?

        for candidateRegion in regions {
            let client = AudnexusClient(region: candidateRegion, transport: transport)
            do {
                var book = try await client.book(asin: asin)
                let chapters = await (try? client.chapters(asin: asin)) ?? []

                if book.series == nil {
                    let audible = AudibleClient(region: candidateRegion, transport: transport)
                    if let prod = try? await audible.product(asin: asin) {
                        if book.series == nil {
                            book.series = prod.series
                        }
                        if book.seriesIndex == nil {
                            book.seriesIndex = prod.seriesIndex
                        }
                        if book.publisher == nil {
                            book.publisher = prod.publisher
                        }
                        if book.year == nil {
                            book.year = prod.year
                        }
                    }
                }

                return MetadataDetails(book: book, chapters: chapters)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MetadataError.notAvailable(region: region.rawValue)
    }
}
