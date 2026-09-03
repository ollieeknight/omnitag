import AVFoundation
import Foundation
import MediaCore

/// Writes tags into the MPEG-4 family (m4a, m4b, mp4, m4v, mov).
///
/// Every write is staged: export to a sibling temp file, re-read it to prove it
/// is still playable, then swap atomically. A crash, a full disk or a failed
/// export can never leave the user's file truncated. This is the one place in
/// the codebase where the paranoid version is the correct version.
public struct MPEG4TagWriter: Sendable {
    private let backups: TagBackupStore?

    public init(backups: TagBackupStore? = nil) {
        self.backups = backups
    }

    public func write(_ tags: TagSet, artwork: [Artwork] = [], to url: URL) async throws {
        guard let container = ContainerFormat(pathExtension: url.pathExtension),
              container.isMPEG4Family
        else { throw TagIOError.unsupportedContainer(url.pathExtension) }

        if let backups {
            let existing = try await AVTagReader().read(url)
            try backups.record(existing.tags, for: url)
        }

        let asset = AVURLAsset(url: url)
        let temp = url.deletingLastPathComponent()
            .appending(path: ".omnitag-\(UUID().uuidString).\(url.pathExtension)")

        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        )
        else { throw TagIOError.unreadable(url, "no passthrough export session") }
        session.metadata = Self.metadataItems(from: tags, artwork: artwork, container: container)

        do {
            try await session.export(to: temp, as: Self.fileType(for: container))
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }

        // Prove the export is readable before it is allowed to replace anything.
        guard let verified = try? await AVTagReader().read(temp), (verified.duration ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, "exported file failed verification")
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }
    }

    static func fileType(for container: ContainerFormat) -> AVFileType {
        switch container {
        case .m4a: .m4a
        case .m4b: .m4a // m4b is m4a with a bookmarkable flag; AVFoundation has no separate type
        case .mov: .mov
        default: .mp4
        }
    }

    static func metadataItems(from tags: TagSet, artwork: [Artwork], container: ContainerFormat? = nil) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        if container == .m4b {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier("itsk/stik")
            item.value = NSNumber(value: 2)
            item.dataType = kCMMetadataBaseDataType_SInt8 as String
            if let copy = item.copy() as? AVMetadataItem {
                items.append(copy)
            }
        }

        for pair in MPEG4KeyMap.pairAtoms {
            let index = tags[pair.index]?.intValue
            let total = tags[pair.total]?.intValue
            guard index != nil || total != nil else { continue }
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier("itsk/\(pair.atom)")
            item.value = MPEG4KeyMap.packedPair(
                index: index, total: total,
                byteCount: pair.atom == "trkn" ? 8 : 6
            ) as NSData
            item.dataType = kCMMetadataBaseDataType_RawData as String
            if let copy = item.copy() as? AVMetadataItem {
                items.append(copy)
            }
        }

        let packedKeys = Set(MPEG4KeyMap.pairAtoms.flatMap { [$0.index, $0.total] })
        for (key, value) in tags.values where !packedKeys.contains(key) {
            guard let string = value.stringValue,
                  let identifier = MPEG4KeyMap.identifier(for: key)
            else { continue }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = string as NSString
            item.extendedLanguageTag = "und"
            if let copy = item.copy() as? AVMetadataItem {
                items.append(copy)
            }
        }
        for art in artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataCoverArt
            // Determine type from magic bytes if possible, or fallback to mimeType mapping
            let type: String = if art.data.starts(with: [0xFF, 0xD8, 0xFF]) {
                "public.jpeg"
            } else if art.data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                "public.png"
            } else {
                art.mimeType == "image/png" ? "public.png" : "public.jpeg"
            }
            item.dataType = type
            item.value = art.data as NSData
            if let copy = item.copy() as? AVMetadataItem {
                items.append(copy)
            }
        }

        return items
    }
}
