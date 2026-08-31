import AVFoundation
import Foundation
import MediaCore

/// Remuxes an MPEG-4 file to inject a QuickTime chapter text track, alongside tags and artwork.
///
/// `AVAssetExportSession` cannot generate or modify chapter tracks; it only copies what is there
/// or handles standard `udta.meta` metadata. To add chapters to a file that lacks them, or to
/// overwrite existing chapters, we must use an `AVAssetWriter` pipeline: pass through the audio
/// track un-encoded, generate a text track containing the chapters, and link the audio track to
/// the text track as its chapter source.
public struct MPEG4ChapterWriter: Sendable {
    private let backups: TagBackupStore?

    public init(backups: TagBackupStore? = nil) {
        self.backups = backups
    }

    public func write(_ tags: TagSet, artwork: [Artwork] = [], chapters: [Chapter], to url: URL) async throws {
        guard let container = ContainerFormat(pathExtension: url.pathExtension), container.isMPEG4Family else {
            throw TagIOError.unsupportedContainer(url.pathExtension)
        }

        if let backups {
            let existing = try await AVTagReader().read(url)
            try backups.record(existing.tags, for: url)
        }

        let temp = url.deletingLastPathComponent().appending(path: ".omnitag-remux-\(UUID().uuidString).\(url.pathExtension)")
        let asset = AVURLAsset(url: url)
        
        // Ensure asset is loaded before proceeding
        _ = try await asset.load(.tracks, .duration)
        
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(url: temp, fileType: MPEG4TagWriter.fileType(for: container))
        
        writer.metadata = MPEG4TagWriter.metadataItems(from: tags, artwork: artwork)
        
        // 1. Copy audio tracks (passthrough)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TagIOError.unreadable(url, "No audio track found")
        }
        
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        if reader.canAdd(audioOutput) { reader.add(audioOutput) }
        
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        if writer.canAdd(audioInput) { writer.add(audioInput) }
        
        // 2. Create the chapter text track
        let chapterInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil)
        // Chapter track must not be enabled by default so it doesn't render as subtitles on screen.
        chapterInput.marksOutputTrackAsEnabled = false 
        
        // Link the audio track to the chapter track
        audioInput.addTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        
        if writer.canAdd(chapterInput) { writer.add(chapterInput) }
        
        let chapterAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: chapterInput)
        
        // 3. Start processing
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        reader.startReading()
        
        let audioGroup = DispatchGroup()
        audioGroup.enter()
        
        let queue = DispatchQueue(label: "MPEG4ChapterWriter.Queue")
        
        // Write chapters
        for chapter in chapters {
            let duration = chapter.duration ?? 1.0
            let timeRange = CMTimeRange(
                start: CMTime(seconds: chapter.start, preferredTimescale: 600),
                duration: CMTime(seconds: duration > 0 ? duration : 1.0, preferredTimescale: 600)
            )
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeUserDataChapter
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = chapter.title as NSString
            item.time = timeRange.start
            item.duration = timeRange.duration
            
            let group = AVTimedMetadataGroup(items: [item], timeRange: timeRange)
            chapterAdaptor.append(group)
        }
        
        final class UncheckedSendable<T>: @unchecked Sendable {
            let value: T
            init(_ value: T) { self.value = value }
        }
        
        let safeAudioInput = UncheckedSendable(audioInput)
        let safeAudioOutput = UncheckedSendable(audioOutput)
        
        // Write audio
        audioInput.requestMediaDataWhenReady(on: queue) {
            let input = safeAudioInput.value
            let output = safeAudioOutput.value
            while input.isReadyForMoreMediaData {
                if let buffer = output.copyNextSampleBuffer() {
                    input.append(buffer)
                } else {
                    input.markAsFinished()
                    audioGroup.leave()
                    break
                }
            }
        }
        
        await withCheckedContinuation { continuation in
            audioGroup.notify(queue: queue) {
                continuation.resume()
            }
        }
        
        // Finish up
        chapterInput.markAsFinished()
        
        if reader.status == .failed {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, reader.error?.localizedDescription ?? "Reader failed")
        }
        
        await writer.finishWriting()
        
        if writer.status == .failed {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, writer.error?.localizedDescription ?? "Writer failed")
        }
        
        // Verify the export
        guard let verified = try? await AVTagReader().read(temp), (verified.duration ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, "remuxed file failed verification")
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }
    }
}
