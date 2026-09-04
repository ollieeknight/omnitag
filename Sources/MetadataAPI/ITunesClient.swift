import Foundation
import MediaCore

/// The iTunes Search API: music, and the only OmniTag provider that needs
/// neither a key nor an account.
///
/// One endpoint, not the usual search-then-detail pair. `/lookup?id=` was
/// checked against the live API and returns nothing `/search` does not — no
/// composer, no copyright, no extra credits — so a detail round trip would
/// buy a second request and no fields. `details(for:)` therefore answers
/// from the candidate it is handed.
public struct ITunesClient: Sendable {
    private let transport: any HTTPTransporting

    public init(transport: any HTTPTransporting = URLSessionTransport()) {
        self.transport = transport
    }

    /// Everything a song result carries, kept so `details(for:)` can answer
    /// without a second request.
    ///
    /// Per-instance, deliberately: a `static` cache is shared by every client
    /// in the process and keyed only by track id, so two searches for the same
    /// track — in different windows, or two tests — resolve to whichever ran
    /// last. The provider holds one client for the wizard's whole session,
    /// which is exactly the lifetime this needs.
    private let recordCache = RecordCache()

    public func searchSongs(_ query: MetadataQuery, limit: Int = 20) async throws -> [MetadataCandidate] {
        guard !query.isEmpty, !query.searchTerms.isEmpty else { throw MetadataError.emptyQuery }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: query.searchTerms),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw MetadataError.malformedResponse("bad URL") }

        let (data, status) = try await transport.data(from: url)
        guard (200 ..< 300).contains(status) else { throw MetadataError.server(status: status) }

        let response: SearchResponse
        do {
            response = try JSONDecoder.api.decode(SearchResponse.self, from: data)
        } catch {
            throw MetadataError.malformedResponse(error.localizedDescription)
        }

        await recordCache.store(response.results.map { ($0.candidateID, $0.record) })
        return response.results.map(\.candidate)
    }

    /// The record built during the search. Falls back to the candidate's own
    /// fields if the cache was cleared between search and selection.
    public func details(for candidate: MetadataCandidate) async -> MetadataDetails {
        if let record = await recordCache.record(for: candidate.id) {
            return MetadataDetails(book: record, chapters: [])
        }
        return MetadataDetails(
            book: MetadataRecord(
                id: candidate.id, title: candidate.title, authors: candidate.authors,
                year: candidate.year, artworkURL: candidate.artworkURL, kind: .music
            ),
            chapters: []
        )
    }

    /// Keyed by track id, so two searches in one wizard session do not make
    /// the earlier results unresolvable.
    private actor RecordCache {
        private var records: [String: MetadataRecord] = [:]

        func store(_ pairs: [(String, MetadataRecord)]) {
            for (id, record) in pairs {
                records[id] = record
            }
        }

        func record(for id: String) -> MetadataRecord? {
            records[id]
        }
    }

    // MARK: wire format

    private struct SearchResponse: Decodable { var results: [Song] }

    private struct Song: Decodable {
        var trackId: Int?
        var trackName: String?
        var artistName: String?
        var collectionName: String?
        var collectionArtistName: String?
        var artworkUrl100: String?
        var releaseDate: String?
        var trackNumber: Int?
        var trackCount: Int?
        var discNumber: Int?
        var discCount: Int?
        var trackTimeMillis: Int?
        var primaryGenreName: String?

        var candidateID: String {
            trackId.map(String.init) ?? ""
        }

        var year: Int? {
            releaseDate.flatMap { Int($0.prefix(4)) }
        }

        /// Whole minutes, matching what `MetadataCandidate.runtimeMinutes`
        /// means everywhere else (Audible reports a book's length the same way).
        var runtimeMinutes: Int? {
            trackTimeMillis.map { $0 / 60000 }
        }

        var candidate: MetadataCandidate {
            MetadataCandidate(
                id: candidateID, title: trackName ?? "", subtitle: collectionName,
                authors: [artistName].compactMap(\.self), narrators: [],
                publisher: nil, year: year, runtimeMinutes: runtimeMinutes,
                series: nil, seriesIndex: nil, summary: nil,
                artworkURL: ITunesArtwork.url(artworkUrl100)
            )
        }

        var record: MetadataRecord {
            MetadataRecord(
                id: candidateID, title: trackName ?? "",
                // A compilation's tracks each have their own artist but share
                // one album artist; a normal album has no collectionArtistName
                // at all, so the track's artist is the right answer there.
                authors: [artistName].compactMap(\.self),
                year: year,
                genres: [primaryGenreName].compactMap(\.self),
                artworkURL: ITunesArtwork.url(artworkUrl100),
                album: collectionName,
                albumArtist: collectionArtistName ?? artistName,
                trackNumber: trackNumber, trackTotal: trackCount,
                discNumber: discNumber, discTotal: discCount,
                kind: .music
            )
        }
    }
}

/// iTunes serves artwork from a CDN keyed by a size path segment, so the
/// 100 px thumbnail the API returns can be asked for at cover resolution
/// instead. `CoverImage` resamples on import regardless.
enum ITunesArtwork {
    static func url(_ thumbnail: String?) -> URL? {
        guard let thumbnail, !thumbnail.isEmpty else { return nil }
        return URL(string: thumbnail.replacingOccurrences(of: "/100x100bb.jpg", with: "/1200x1200bb.jpg"))
    }
}
