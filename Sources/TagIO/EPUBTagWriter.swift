import Foundation
import MediaCore

/// Writes an EPUB's metadata by rebuilding the archive with a new package
/// document and every other entry copied across as-is.
///
/// The OPF itself is edited surgically — only the bytes inside `<metadata>`
/// change — so the manifest, spine, guide and every namespace declaration the
/// file carries survive untouched. Regenerating the document would be shorter
/// and would throw the book away.
public struct EPUBTagWriter: Sendable {
    private let backups: TagBackupStore?

    public init(backups: TagBackupStore? = nil) {
        self.backups = backups
    }

    public func write(_ tags: TagSet, artwork: [Artwork] = [], to url: URL) throws {
        let archive = try ZipArchive(url: url)
        let opfPath = try EPUBReader.packagePath(in: archive, url: url)
        let package = try OPFDocument(try archive.data(at: opfPath))

        if let backups {
            try backups.record(EPUBKeyMap.tags(from: package), for: url)
        }

        var replacements: [String: Data] = [
            opfPath: try package.replacingMetadata(with: EPUBKeyMap.metadataXML(for: tags, from: package))
        ]

        // A cover can only replace one that already exists: adding a new
        // manifest item would mean rewriting the manifest and the spine, which
        // is bookbinding, not tagging.
        if let cover = artwork.first, let href = package.coverHref {
            replacements[EPUBReader.resolve(href, relativeTo: opfPath)] = cover.data
        }

        let temporary = url.deletingLastPathComponent()
            .appending(path: ".omnitag-\(UUID().uuidString).epub")
        do {
            try archive.rebuild(to: temporary, replacing: replacements)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }

        // Prove the rebuilt archive parses and still says what we meant before
        // anything replaces the user's file.
        do {
            let verification = try ZipArchive(url: temporary)
            let rewritten = try OPFDocument(try verification.data(at: opfPath))
            let readBack = EPUBKeyMap.tags(from: rewritten)
            for key in EPUBKeyMap.managedKeys {
                guard let intended = tags[key]?.stringValue, !intended.isEmpty else { continue }
                guard readBack[key]?.stringValue == intended else {
                    throw TagIOError.writeFailed(
                        url, "verification failed: \(key) read back as \(readBack[key]?.stringValue ?? "nothing")")
                }
            }
            guard verification.paths == archive.paths else {
                throw TagIOError.writeFailed(url, "verification failed: the rebuilt archive lost entries")
            }
        } catch let error as TagIOError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw TagIOError.writeFailed(url, "verification failed: \(error.localizedDescription)")
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }
    }
}
