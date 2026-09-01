import Foundation

/// Audible's own catalogue API. Unauthenticated, undocumented, and the only one
/// of the two that can *search* — Audnexus is ASIN-keyed and has no search.
///
/// Endpoint shapes were verified live against the UK and US storefronts rather
/// than taken from any write-up; the Mp3tag community script confirms only that
/// the regional domains are the ones listed in `AudibleRegion`.
public struct AudibleClient: Sendable {
    private let region: AudibleRegion
    private let transport: any HTTPTransporting

    public init(region: AudibleRegion = .unitedKingdom, transport: any HTTPTransporting = URLSessionTransport()) {
        self.region = region
        self.transport = transport
    }

    private static let responseGroups =
        "contributors,product_desc,product_attrs,media,series"

    public func search(_ query: MetadataQuery, limit: Int = 20) async throws -> [MetadataCandidate] {
        // An ASIN is an exact identifier, not a search term, so it is answered
        // before the query is judged empty — it carries no keywords by design.
        if let asin = query.asin, !asin.isEmpty { return [try await product(asin: asin)] }
        guard !query.isEmpty, !query.searchTerms.isEmpty else { throw MetadataError.emptyQuery }

        var components = URLComponents()
        components.scheme = "https"
        components.host = region.apiHost
        components.path = "/1.0/catalog/products"
        var items = [
            URLQueryItem(name: "num_results", value: String(limit)),
            URLQueryItem(name: "response_groups", value: Self.responseGroups),
            URLQueryItem(name: "image_sizes", value: "500,1024"),
        ]
        items.append(URLQueryItem(name: "keywords", value: query.searchTerms))
        components.queryItems = items

        guard let url = components.url else { throw MetadataError.malformedResponse("bad URL") }
        let (data, status) = try await transport.data(from: url)
        guard (200..<300).contains(status) else { throw MetadataError.server(status: status) }

        do {
            return try JSONDecoder.api.decode(SearchResponse.self, from: data).products.map(\.candidate)
        } catch {
            throw MetadataError.malformedResponse(error.localizedDescription)
        }
    }

    /// The by-ASIN endpoint, which returns one product rather than a search.
    public func product(asin: String) async throws -> MetadataCandidate {
        var components = URLComponents()
        components.scheme = "https"
        components.host = region.apiHost
        components.path = "/1.0/catalog/products/\(asin)"
        components.queryItems = [
            URLQueryItem(name: "response_groups", value: Self.responseGroups),
            URLQueryItem(name: "image_sizes", value: "500,1024"),
        ]
        guard let url = components.url else { throw MetadataError.malformedResponse("bad URL") }
        let (data, status) = try await transport.data(from: url)
        guard (200..<300).contains(status) else { throw MetadataError.server(status: status) }
        do {
            return try JSONDecoder.api.decode(ProductResponse.self, from: data).product.candidate
        } catch {
            throw MetadataError.malformedResponse(error.localizedDescription)
        }
    }

    // MARK: wire format

    private struct ProductResponse: Decodable {
        var product: Product
    }

    private struct SearchResponse: Decodable {
        var products: [Product]
    }

    private struct Product: Decodable {
        struct Person: Decodable { var name: String }
        struct Series: Decodable { var title: String?; var sequence: String? }

        var asin: String
        var title: String
        var subtitle: String?
        var authors: [Person]?
        var narrators: [Person]?
        var publisherName: String?
        var releaseDate: String?
        var issueDate: String?
        var runtimeLengthMin: Int?
        var series: [Series]?
        var merchandisingSummary: String?
        var productImages: [String: String]?

        var candidate: MetadataCandidate {
            MetadataCandidate(
                id: asin, title: title, subtitle: subtitle,
                authors: authors?.map(\.name) ?? [],
                narrators: narrators?.map(\.name) ?? [],
                publisher: publisherName,
                year: (releaseDate ?? issueDate).flatMap { Int($0.prefix(4)) },
                runtimeMinutes: runtimeLengthMin,
                series: series?.first?.title,
                seriesIndex: series?.first?.sequence.flatMap { Int($0) },
                summary: merchandisingSummary.map(Self.strippingHTML),
                artworkURL: Self.largestImage(productImages))
        }

        /// Audible returns the image set keyed by pixel width, as strings.
        static func largestImage(_ images: [String: String]?) -> URL? {
            guard let images else { return nil }
            let widest = images.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            return widest.flatMap { URL(string: $0.value) }
        }

        /// Summaries arrive as HTML. The inspector shows plain text.
        static func strippingHTML(_ html: String) -> String {
            html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

extension JSONDecoder {
    /// Audible and Audnexus both use snake_case and camelCase in places; the
    /// clients decode with converted keys and spell properties in Swift.
    static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
