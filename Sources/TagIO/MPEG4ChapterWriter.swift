import AVFoundation
import Foundation
import MediaCore

/// Rewrites an MPEG-4 file with a QuickTime chapter text track, alongside its
/// tags and artwork.
///
/// `AVAssetExportSession` cannot write a chapter track — worse, a passthrough
/// export silently drops the one the file arrived with — so chapters mean an
/// `AVAssetWriter` pipeline: copy the audio through un-decoded, generate a text
/// track beside it, and associate the two. The audio is never re-encoded, but
/// every sample is copied, so this is the slow path and `MediaTagWriter` only
/// takes it for files that actually have chapters.
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

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TagIOError.unreadable(url, "no audio track")
        }

        let temp = url.deletingLastPathComponent()
            .appending(path: ".omnitag-remux-\(UUID().uuidString).\(url.pathExtension)")
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(url: temp, fileType: MPEG4TagWriter.fileType(for: container))
        // Container included, so an m4b keeps the `stik` flag that makes it an
        // audiobook rather than a very long song.
        writer.metadata = MPEG4TagWriter.metadataItems(from: tags, artwork: artwork, container: container)

        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        guard reader.canAdd(audioOutput) else {
            throw TagIOError.writeFailed(url, "cannot read the audio track")
        }
        reader.add(audioOutput)

        let audioInput = await AVAssetWriterInput(
            mediaType: .audio, outputSettings: nil,
            sourceFormatHint: try? audioTrack.load(.formatDescriptions).first
        )
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw TagIOError.writeFailed(url, "cannot write the audio track")
        }
        writer.add(audioInput)

        let chapterInput = try AVAssetWriterInput(
            mediaType: .text, outputSettings: nil,
            sourceFormatHint: Self.textFormatDescription(url)
        )
        chapterInput.marksOutputTrackAsEnabled = false
        chapterInput.expectsMediaDataInRealTime = false
        audioInput.addTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        guard writer.canAdd(chapterInput) else {
            throw TagIOError.writeFailed(url, "cannot write the chapter track")
        }
        writer.add(chapterInput)

        let samples = try Self.samples(
            for: chapters, duration: duration.seconds,
            format: Self.textFormatDescription(url), url: url
        )

        guard writer.startWriting() else {
            throw TagIOError.writeFailed(url, writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw TagIOError.writeFailed(url, reader.error?.localizedDescription ?? "could not start reading")
        }

        // Both tracks are fed from their own queue. Appending the chapters first
        // and the audio afterwards deadlocks: the writer stops accepting text
        // samples until the audio it is interleaving with catches up, and the
        // audio has not started. Real books have enough chapters to hit that.
        // Both tracks are fed from their own queue. Appending the chapters first
        // and the audio afterwards deadlocks: the writer stops accepting text
        // samples until the audio it is interleaving with catches up, and the
        // audio has not started. Real books have enough chapters to hit that.
        let feed = Feed(
            audioInput: audioInput, audioOutput: audioOutput,
            chapterInput: chapterInput, chapterSamples: samples
        )

        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            group.enter()
            group.enter()
            feed.startChapters(on: DispatchQueue(label: "omnitag.chapters"), group)
            feed.startAudio(on: DispatchQueue(label: "omnitag.audio"), group)
            group.notify(queue: .global()) { continuation.resume() }
        }

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, reader.error?.localizedDescription ?? "could not read the audio")
        }

        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, writer.error?.localizedDescription ?? "the remux failed")
        }

        // Prove the remux is playable *and* still chaptered before it is allowed
        // to replace the user's file.
        guard let verified = try? await AVTagReader().read(temp),
              (verified.duration ?? 0) > 0,
              verified.chapters.count == chapters.count
        else {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, "the remuxed file failed verification")
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }
    }

    /// Pumps both tracks. AVFoundation's reader and writer objects are not
    /// `Sendable` but are documented as safe to drive from one queue each, which
    /// is exactly what this does — one queue per input, a lock over the cursor.
    private final class Feed: @unchecked Sendable {
        private let audioInput: AVAssetWriterInput
        private let audioOutput: AVAssetReaderTrackOutput
        private let chapterInput: AVAssetWriterInput
        private let chapterSamples: [CMSampleBuffer]
        private let lock = NSLock()
        private var next = 0

        init(
            audioInput: AVAssetWriterInput, audioOutput: AVAssetReaderTrackOutput,
            chapterInput: AVAssetWriterInput, chapterSamples: [CMSampleBuffer]
        ) {
            self.audioInput = audioInput
            self.audioOutput = audioOutput
            self.chapterInput = chapterInput
            self.chapterSamples = chapterSamples
        }

        func startChapters(on queue: DispatchQueue, _ group: DispatchGroup) {
            chapterInput.requestMediaDataWhenReady(on: queue) { [self] in
                while chapterInput.isReadyForMoreMediaData {
                    lock.lock()
                    let sample = next < chapterSamples.count ? chapterSamples[next] : nil
                    next += sample == nil ? 0 : 1
                    lock.unlock()
                    guard let sample else {
                        chapterInput.markAsFinished()
                        group.leave()
                        return
                    }
                    chapterInput.append(sample)
                }
            }
        }

        func startAudio(on queue: DispatchQueue, _ group: DispatchGroup) {
            audioInput.requestMediaDataWhenReady(on: queue) { [self] in
                while audioInput.isReadyForMoreMediaData {
                    guard let buffer = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    audioInput.append(buffer)
                }
            }
        }
    }

    /// A QuickTime chapter track is a run of adjacent text samples: each lasts
    /// until the next chapter starts, the last until the end of the audio. A
    /// chapter's stored duration is ignored — a mark the user just dropped at
    /// the playhead has none, and a gap between samples hides the chapter after it.
    private static func samples(
        for chapters: [Chapter], duration: TimeInterval,
        format: CMFormatDescription, url: URL
    ) throws -> [CMSampleBuffer] {
        let ordered = chapters
            .sorted { $0.start < $1.start }
            .filter { $0.start.isFinite && $0.start < duration }

        return try ordered.enumerated().map { offset, chapter in
            let start = max(0, chapter.start)
            let end = offset + 1 < ordered.count ? min(ordered[offset + 1].start, duration) : duration

            // A QuickTime text sample is a big-endian UInt16 length followed by
            // the bytes themselves.
            let text = [UInt8](chapter.title.utf8)
            var data = Data()
            withUnsafeBytes(of: UInt16(min(text.count, .max)).bigEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: text)

            var block: CMBlockBuffer?
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(seconds: max(end - start, 0.001), preferredTimescale: 600),
                presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600),
                decodeTimeStamp: .invalid
            )
            var size = data.count

            let created: OSStatus = data.withUnsafeBytes { pointer in
                var status = CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                    blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                    dataLength: data.count, flags: 0, blockBufferOut: &block
                )
                guard status == noErr, let block, let base = pointer.baseAddress else { return status }
                status = CMBlockBufferReplaceDataBytes(
                    with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count
                )
                guard status == noErr else { return status }
                return CMSampleBufferCreate(
                    allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                    makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
                )
            }

            guard created == noErr, let sample else {
                throw TagIOError.writeFailed(url, "could not build chapter \(offset + 1)")
            }
            return sample
        }
    }

    /// The 'text' sample description QuickTime expects. The style values are the
    /// inert defaults a chapter track carries: nothing here is ever drawn.
    private static func textFormatDescription(_ url: URL) throws -> CMFormatDescription {
        let extensions: [String: Any] = [
            "BackgroundColor": ["Blue": 0, "Green": 0, "Red": 0],
            "DefaultFontName": "",
            "DefaultStyle": [
                "Ascent": 0, "Font": 0, "FontFace": 0, "FontSize": 26228,
                "ForegroundColor": ["Blue": 1, "Green": 1, "Red": 24930],
                "Height": 0, "StartChar": 65536
            ],
            "DefaultTextBox": ["Bottom": 0, "Left": 0, "Right": 0, "Top": 0],
            "DisplayFlags": 1,
            "TextJustification": 0
        ]
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Text,
            mediaSubType: 0x7465_7874, // 'text'
            extensions: extensions as CFDictionary, formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw TagIOError.writeFailed(url, "could not describe the chapter track")
        }
        return description
    }
}
