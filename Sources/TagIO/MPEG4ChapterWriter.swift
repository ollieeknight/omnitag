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
        let writer = try AVAssetWriter(url: temp, fileType: .mp4)
        
        writer.metadata = MPEG4TagWriter.metadataItems(from: tags, artwork: artwork)
        
        // 1. Copy audio tracks (passthrough)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TagIOError.unreadable(url, "No audio track found")
        }
        
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        guard reader.canAdd(audioOutput) else {
            throw TagIOError.writeFailed(url, "Cannot add audio output to reader")
        }
        reader.add(audioOutput)
        
        let formats = try? await audioTrack.load(.formatDescriptions)
        let format = formats?.first
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        guard writer.canAdd(audioInput) else {
            throw TagIOError.writeFailed(url, "Cannot add audio input to writer")
        }
        writer.add(audioInput)
        
        // 2. Create the chapter text track (QuickTime Text format)
        var textDesc: CMFormatDescription?
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
        
        func fourCharCode(_ string: String) -> FourCharCode {
            var result: FourCharCode = 0
            for char in string.utf16 {
                result = (result << 8) + FourCharCode(char)
            }
            return result
        }
        
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Text,
            mediaSubType: fourCharCode("text"),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &textDesc
        )
        
        guard status == noErr, let desc = textDesc else {
            throw TagIOError.writeFailed(url, "Failed to create text format description")
        }
        
        let chapterInput = AVAssetWriterInput(
            mediaType: .text, 
            outputSettings: nil, 
            sourceFormatHint: desc
        )
        chapterInput.languageCode = "en"
        chapterInput.extendedLanguageTag = "en"
        chapterInput.marksOutputTrackAsEnabled = false
        chapterInput.expectsMediaDataInRealTime = false
        
        // Link the audio track to the chapter track
        audioInput.addTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        
        guard writer.canAdd(chapterInput) else {
            throw TagIOError.writeFailed(url, "Cannot add chapter input to writer")
        }
        writer.add(chapterInput)
        
        // 3. Start processing
        if !writer.startWriting() {
            throw TagIOError.writeFailed(url, writer.error?.localizedDescription ?? "Failed to start writing")
        }
        writer.startSession(atSourceTime: .zero)
        if !reader.startReading() {
            throw TagIOError.writeFailed(url, reader.error?.localizedDescription ?? "Failed to start reading")
        }
        
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
            
            let textBytes = [UInt8](chapter.title.utf8)
            let length = UInt16(textBytes.count).bigEndian
            var data = Data()
            withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
            data.append(contentsOf: textBytes)
            
            var blockBuffer: CMBlockBuffer?
            data.withUnsafeBytes { ptr in
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: nil,
                    blockLength: data.count,
                    blockAllocator: nil,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: data.count,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
                if let bb = blockBuffer {
                    CMBlockBufferReplaceDataBytes(
                        with: ptr.baseAddress!,
                        blockBuffer: bb,
                        offsetIntoDestination: 0,
                        dataLength: data.count
                    )
                }
            }
            
            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: timeRange.duration,
                presentationTimeStamp: timeRange.start,
                decodeTimeStamp: .invalid
            )
            var sampleSize = data.count
            
            if let bb = blockBuffer {
                CMSampleBufferCreate(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: bb,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: desc,
                    sampleCount: 1,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing,
                    sampleSizeEntryCount: 1,
                    sampleSizeArray: &sampleSize,
                    sampleBufferOut: &sampleBuffer
                )
            }
            
            if let sb = sampleBuffer {
                while !chapterInput.isReadyForMoreMediaData {
                    usleep(100)
                }
                chapterInput.append(sb)
            }
        }
        chapterInput.markAsFinished()
        
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
