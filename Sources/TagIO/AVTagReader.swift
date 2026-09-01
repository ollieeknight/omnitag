import AVFoundation
import Foundation
import MediaCore

public enum TagIOError: Error, Equatable {
    case unsupportedContainer(String)
    case unreadable(URL, String)
    case writeFailed(URL, String)
}

/// Reads whatever AVFoundation understands: the whole MP4 family plus mp3,
/// wav and aiff. One backend, zero dependencies, most of the library covered.
/// Formats AVFoundation refuses (flac tags, mkv, ogg) get their own readers.
public struct AVTagReader: Sendable {
    public init() {}

    public func read(_ url: URL) async throws -> MediaItem {
        guard let container = ContainerFormat(pathExtension: url.pathExtension) else {
            throw TagIOError.unsupportedContainer(url.pathExtension)
        }
        let asset = AVURLAsset(url: url)
        let duration: TimeInterval
        let metadata: [AVMetadataItem]
        do {
            let (loadedDuration, loadedMetadata) = try await asset.load(.duration, .metadata)
            duration = CMTimeGetSeconds(loadedDuration)
            metadata = loadedMetadata
        } catch {
            throw TagIOError.unreadable(url, error.localizedDescription)
        }

        var tags = TagSet()
        var artwork: [Artwork] = []
        for item in metadata {
            if isArtwork(item) {
                if let data = try? await item.load(.dataValue) {
                    artwork.append(Artwork(data: data, mimeType: Artwork.sniffMimeType(data)))
                }
            } else if let (indexKey, totalKey) = MPEG4KeyMap.pairKeys(for: item) {
                if let data = try? await item.load(.dataValue) {
                    let pair = MPEG4KeyMap.unpackPair(data)
                    if let index = pair.index { tags[indexKey] = .number(index) }
                    if let total = pair.total { tags[totalKey] = .number(total) }
                }
            } else if let string = try? await item.load(.stringValue), !string.isEmpty {
                apply(string, from: item, to: &tags)
            }
        }

        return MediaItem(
            url: url, kind: container.defaultKind, container: container,
            duration: duration.isFinite ? duration : nil,
            tags: tags, chapters: await Self.chapters(of: asset), artwork: artwork)
    }

    private func isArtwork(_ item: AVMetadataItem) -> Bool {
        item.commonKey == .commonKeyArtwork
            || item.identifier == .iTunesMetadataCoverArt
            || ID3KeyMap.frameID(fromIdentifier: item.identifier?.rawValue ?? "") == "APIC"
    }

    /// ID3 and MPEG-4 name the same field differently, so the frame's own
    /// namespace decides which table reads it.
    private func apply(_ string: String, from item: AVMetadataItem, to tags: inout TagSet) {
        guard let raw = item.identifier?.rawValue else { return }

        if let frame = ID3KeyMap.frameID(fromIdentifier: raw) {
            if let pair = ID3KeyMap.pairedFrames[frame] {
                let (index, total) = ID3KeyMap.split(string)
                if let index { tags[pair.index] = .number(index) }
                if let total { tags[pair.total] = .number(total) }
                return
            }
            let key = ID3KeyMap.key(forIdentifier: raw)
            tags[key] = ID3KeyMap.value(string, for: key)
            return
        }

        guard let key = MPEG4KeyMap.key(for: item) else { return }
        tags[key] = MPEG4KeyMap.value(string, for: key)
    }

    /// Chapter titles live in a disabled text track, reachable only through the
    /// chapter-group API. Locale is whatever the file declares — audiobooks
    /// routinely use `und`, so asking for "en" finds nothing.
    static func chapters(of asset: AVAsset) async -> [Chapter] {
        guard let locale = try? await asset.load(.availableChapterLocales).first,
              let groups = try? await asset.loadChapterMetadataGroups(
                  withTitleLocale: locale, containingItemsWithCommonKeys: [])
        else { return [] }

        var chapters: [Chapter] = []
        for (index, group) in groups.enumerated() {
            let titleItem = group.items.first { $0.commonKey == .commonKeyTitle }
            let title = (try? await titleItem?.load(.stringValue)) ?? nil
            chapters.append(Chapter(
                index: index,
                start: CMTimeGetSeconds(group.timeRange.start),
                duration: CMTimeGetSeconds(group.timeRange.duration),
                title: title ?? "Chapter \(index + 1)"))
        }
        return chapters
    }
}
