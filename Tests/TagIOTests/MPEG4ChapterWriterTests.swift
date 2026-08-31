import XCTest
import AVFoundation
@testable import TagIO
@testable import MediaCore

final class MPEG4ChapterWriterTests: XCTestCase {
    
    var tempURL: URL!
    
    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
    }
    
    override func tearDown() {
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        super.tearDown()
    }
    
    func createSilentAudioFile(at url: URL) throws {
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 128000
        ]
        
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)
        
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        // Write 1 second of silence
        var formatDesc: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc)
        
        guard let desc = formatDesc else { throw NSError(domain: "test", code: 1, userInfo: nil) }
        
        var blockBuffer: CMBlockBuffer?
        let numFrames = 44100
        let dataSize = numFrames * 4
        var data = Data(count: dataSize)
        
        data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: ptr.baseAddress,
                blockLength: dataSize,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataSize,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        
        if let bb = blockBuffer {
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: desc,
                sampleCount: numFrames,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
        }
        
        if let sb = sampleBuffer {
            while !audioInput.isReadyForMoreMediaData { usleep(100) }
            audioInput.append(sb)
        }
        
        audioInput.markAsFinished()
        writer.finishWriting {}
    }
    
    func testChapterWriting() async throws {
        // 1. Create a base file
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try createSilentAudioFile(at: baseURL)
        
        // 2. Write chapters
        let chapters = [
            Chapter(index: 1, start: 0, title: "Intro"),
            Chapter(index: 2, start: 0.5, title: "Outro")
        ]
        
        let writer = MPEG4ChapterWriter()
        // Use the write method directly since that's what the writer exposes
        try await writer.write(TagSet(), chapters: chapters, to: baseURL)
        
        // 3. Verify chapters using AVTagReader
        let asset = AVAsset(url: baseURL)
        let readChapters = await AVTagReader.chapters(of: asset)
        
        XCTAssertEqual(readChapters.count, 2)
        XCTAssertEqual(readChapters[0].title, "Intro")
        XCTAssertEqual(readChapters[1].title, "Outro")
    }
}
