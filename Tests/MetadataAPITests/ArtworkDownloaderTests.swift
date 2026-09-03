import Foundation
import MediaCore
@testable import MetadataAPI
import Testing

struct ArtworkStubTransport: HTTPTransporting {
    let responseData: Data
    let statusCode: Int
    let expectedURL: URL?

    func data(from url: URL) async throws -> (Data, Int) {
        if let expected = expectedURL {
            #expect(url == expected)
        }
        return (responseData, statusCode)
    }
}

@Suite("ArtworkDownloader")
struct ArtworkDownloaderTests {
    @Test("downloads image and detects JPEG")
    func downloadsJPEG() async throws {
        // A minimal valid JPEG magic byte sequence
        let jpegBytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDB]
        let data = Data(jpegBytes)
        let transport = ArtworkStubTransport(responseData: data, statusCode: 200, expectedURL: URL(string: "https://example.com/cover.jpg"))
        let downloader = ArtworkDownloader(transport: transport)

        let artwork = try await downloader.download(from: #require(URL(string: "https://example.com/cover.jpg")))

        #expect(artwork.data == data)
        #expect(artwork.mimeType == "image/jpeg")
        #expect(artwork.role == .cover)
    }

    @Test("downloads image and detects PNG")
    func downloadsPNG() async throws {
        // PNG magic bytes
        let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let data = Data(pngBytes)
        let transport = ArtworkStubTransport(responseData: data, statusCode: 200, expectedURL: URL(string: "https://example.com/cover.png"))
        let downloader = ArtworkDownloader(transport: transport)

        let artwork = try await downloader.download(from: #require(URL(string: "https://example.com/cover.png")))

        #expect(artwork.data == data)
        #expect(artwork.mimeType == "image/png")
    }

    @Test("throws on server error")
    func throwsServerError() async throws {
        let transport = ArtworkStubTransport(responseData: Data(), statusCode: 404, expectedURL: URL?(nil))
        let downloader = ArtworkDownloader(transport: transport)

        do {
            _ = try await downloader.download(from: #require(URL(string: "https://example.com/missing.jpg")))
            Issue.record("Should have thrown")
        } catch let MetadataError.server(status, _) {
            #expect(status == 404)
        } catch {
            Issue.record("Threw wrong error type: \(error)")
        }
    }
}
