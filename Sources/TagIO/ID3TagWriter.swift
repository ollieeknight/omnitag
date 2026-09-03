import Foundation
import MediaCore

/// Writes ID3v2.4 tags into mp3 files.
///
/// The audio is never decoded, re-encoded or even read past: the file is
/// `[tag][audio]`, so a write is "build a new tag block, copy the audio bytes
/// across verbatim". Same staged-temp-then-atomic-swap discipline as the
/// MPEG-4 writer, for the same reason.
public struct ID3TagWriter: Sendable {
    private let backups: TagBackupStore?

    public init(backups: TagBackupStore? = nil) {
        self.backups = backups
    }

    public func write(_ tags: TagSet, artwork: [Artwork] = [], to url: URL) async throws {
        guard ContainerFormat(pathExtension: url.pathExtension) == .mp3 else {
            throw TagIOError.unsupportedContainer(url.pathExtension)
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw TagIOError.unreadable(url, "cannot open file")
        }

        let existing = ID3v2.parse(data)
        if let existing {
            // Refusing beats guessing: rewriting a v2.2 or unsynchronised tag
            // as v2.4 would drop frames we cannot faithfully re-encode.
            guard existing.version >= 3 else {
                throw TagIOError.writeFailed(url, "ID3v2.\(existing.version) tags are not supported")
            }
            guard !existing.isUnsynchronised else {
                throw TagIOError.writeFailed(url, "unsynchronised ID3 tags are not supported")
            }
            if let backups {
                try backups.record(ID3v2.tagSet(from: existing), for: url)
            }
        }

        let audio = data.dropFirst(existing?.totalSize ?? 0)
        var merged = ID3v2.merge(tags, into: upgraded(existing?.frames ?? []))

        merged.removeAll { $0.id == "APIC" }
        for art in artwork {
            var payload = Data([0x00]) // Text encoding: ISO-8859-1 for mime type and description
            payload.append(contentsOf: Array(art.mimeType.utf8))
            payload.append(0x00) // null terminator for mime type
            let pictureType: UInt8 = art.role == .cover ? 0x03 : 0x00 // 3 = front cover, 0 = other
            payload.append(pictureType)
            payload.append(0x00) // null terminator for empty description
            payload.append(art.data)
            merged.append(ID3v2.Frame(id: "APIC", flags: [0, 0], payload: payload))
        }

        var output = ID3v2.serialise(merged)
        output.append(audio)

        let temp = url.deletingLastPathComponent()
            .appending(path: ".omnitag-\(UUID().uuidString).mp3")
        do {
            try output.write(to: temp, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }

        // Prove the new tag parses and the audio survived before replacing anything.
        guard let verification = try? Data(contentsOf: temp),
              let parsed = ID3v2.parse(verification),
              verification.count - parsed.totalSize == audio.count
        else {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, "written file failed verification")
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }
    }

    /// v2.3 frames that v2.4 renamed. Keeping both would leave a file claiming
    /// two release years, and players disagree about which one wins.
    private func upgraded(_ frames: [ID3v2.Frame]) -> [ID3v2.Frame] {
        frames.filter { !ID3KeyMap.supersededFrameIDs.contains($0.id) }
    }
}
