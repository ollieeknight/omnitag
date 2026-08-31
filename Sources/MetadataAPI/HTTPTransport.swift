import Foundation

/// The whole surface the clients need from the network. One method, so tests
/// stub it in three lines instead of standing up a URLProtocol.
public protocol HTTPTransporting: Sendable {
    func data(from url: URL) async throws -> (Data, Int)
}

public enum MetadataError: Error, Equatable {
    case emptyQuery
    case server(status: Int)
    case notAvailable(region: String)
    case malformedResponse(String)
    case transport(String)
}

public struct URLSessionTransport: HTTPTransporting {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func data(from url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        // Audible's API is unauthenticated but does look at the agent string.
        request.setValue("OmniTag/0.1 (+https://github.com/omnitag)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw MetadataError.transport(error.localizedDescription)
        }
    }
}

/// Audible runs one catalogue per storefront, and a book can exist in one and
/// not another — the developer's own Laura Palmer audiobook is US-only, which
/// is exactly the case this enum exists to handle.
public enum AudibleRegion: String, Sendable, CaseIterable, Codable {
    case unitedKingdom = "uk"
    case unitedStates = "us"
    case canada = "ca"
    case australia = "au"
    case germany = "de"
    case france = "fr"
    case spain = "es"
    case italy = "it"
    case japan = "jp"

    public var apiHost: String {
        switch self {
        case .unitedKingdom: "api.audible.co.uk"
        case .unitedStates: "api.audible.com"
        case .canada: "api.audible.ca"
        case .australia: "api.audible.com.au"
        case .germany: "api.audible.de"
        case .france: "api.audible.fr"
        case .spain: "api.audible.es"
        case .italy: "api.audible.it"
        case .japan: "api.audible.co.jp"
        }
    }

    public var displayName: String {
        switch self {
        case .unitedKingdom: "Audible UK"
        case .unitedStates: "Audible US"
        case .canada: "Audible CA"
        case .australia: "Audible AU"
        case .germany: "Audible DE"
        case .france: "Audible FR"
        case .spain: "Audible ES"
        case .italy: "Audible IT"
        case .japan: "Audible JP"
        }
    }
}
