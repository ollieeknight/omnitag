import AVFoundation
import Foundation
import MediaCore

/// What the audio looks like around a chapter mark.
///
/// No provider publishes where a *particular rip's* chapters should fall, so
/// the audio is the only witness. But it is a witness that has to be read
/// carefully, because there is more than one correct shape:
///
/// - **Horus Rising**: prose, a long digital silence, then the next chapter.
///   The marks sit ~2 s *into* the silence, so every skip replays dead air.
/// - **A Thousand Sons**: prose, a pause, a spoken "Chapter Two", another
///   pause, then prose. The marks sit *on the announcement*, deliberately —
///   which is audio, not silence, and perfectly correct.
///
/// So this type **reports the shape and does not pass judgement**. It says
/// how far back the previous audio stopped and how soon sound resumes, and
/// flags only the one unambiguous fault: a mark mid-sentence with no pause
/// anywhere near it. A checker that called A Thousand Sons wrong would be
/// worse than no checker, because it would teach the user to ignore it.
///
/// No dependency: `AVAssetReader` decodes the window and the arithmetic is a
/// root-mean-square. Fingerprinting is not needed to ask "is this quiet".
public enum ChapterBoundaryCheck: Sendable {
    /// What was found around one mark. Descriptive, not a verdict.
    public struct Result: Sendable, Equatable {
        public let index: Int
        public let start: TimeInterval

        /// Loudness at the mark itself, 0 (digital silence) to 1.
        public let level: Float

        /// How long before the mark the previous audio stopped, when there is
        /// a pause within reach. `nil` when sound runs right up to the mark.
        public let silenceBefore: TimeInterval?

        /// How long after the mark sound resumes, when the mark is in a pause.
        public let silenceAfter: TimeInterval?

        /// The nearest pause when the mark is mid-sentence — the one case
        /// worth acting on. `nil` otherwise, including when the mark sits on
        /// deliberate audio like a spoken chapter announcement.
        public let nearestPause: TimeInterval?

        public init(
            index: Int, start: TimeInterval, level: Float,
            silenceBefore: TimeInterval?, silenceAfter: TimeInterval?, nearestPause: TimeInterval?
        ) {
            self.index = index
            self.start = start
            self.level = level
            self.silenceBefore = silenceBefore
            self.silenceAfter = silenceAfter
            self.nearestPause = nearestPause
        }

        /// True only for the unambiguous fault: the mark is in continuous
        /// audio with no pause either side within the search window, so it
        /// cuts a sentence in half.
        public var isMidSentence: Bool {
            level >= Self.silenceThreshold && silenceBefore == nil && silenceAfter == nil
        }

        /// A plain-language description of what surrounds this mark, for the
        /// UI to show instead of a pass/fail badge.
        public var summary: String {
            if isMidSentence {
                if let pause = nearestPause {
                    return String(format: "Mid-sentence. Nearest pause %+.1fs.", pause)
                }
                return "Mid-sentence, with no pause nearby."
            }
            if level < Self.silenceThreshold {
                if let before = silenceBefore, before > 1 {
                    return String(format: "In a pause, %.1fs after the previous audio ended.", before)
                }
                return "At the start of a pause."
            }
            // Audio at the mark, but a pause just before it: the shape of a
            // spoken chapter announcement.
            if let before = silenceBefore {
                return String(format: "On audio, %.1fs after a pause — likely a chapter announcement.", before)
            }
            return "On audio."
        }

        static let silenceThreshold: Float = 0.002
    }

    /// How far either side of a mark to look. Deliberately narrow: a wide
    /// search always finds *a* silence — every paragraph break is one — so it
    /// stops being evidence about this boundary. Measured at ±60 s the
    /// suggestions became noise (−57 s and +34 s in one book); ±10 s matches
    /// the real error.
    static let searchWindow: TimeInterval = 10

    /// Checks each chapter's start. The first is skipped: it begins at zero
    /// by definition, so there is nothing to verify.
    public static func check(_ chapters: [Chapter], in url: URL) async throws -> [Result] {
        let asset = AVURLAsset(url: url)
        // A file AVFoundation cannot open has no boundaries to report, which
        // is an answer rather than a failure: this check is advisory, and it
        // must never be what stops a user editing chapters.
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }

        var results: [Result] = []
        for chapter in chapters where chapter.start > 1 {
            let samples = try await self.samples(
                of: track, in: asset,
                from: chapter.start - searchWindow, seconds: searchWindow * 2
            )
            guard !samples.isEmpty else { continue }
            results.append(measure(samples, index: chapter.index, start: chapter.start))
        }
        return results
    }

    static func measure(_ samples: [Float], index: Int, start: TimeInterval) -> Result {
        let level = rms(samples, around: searchWindow)
        let before = silenceRunningBack(samples, from: searchWindow)
        let after = silenceRunningForward(samples, from: searchWindow)
        let midSentence = level >= Result.silenceThreshold && before == nil && after == nil

        return Result(
            index: index, start: start, level: level,
            silenceBefore: before, silenceAfter: after,
            nearestPause: midSentence ? nearestPause(samples) : nil
        )
    }

    /// 8 kHz mono is plenty: this measures loudness, never content.
    private static let sampleRate = 8000.0

    /// A short window on purpose. A full second straddles the moment sound
    /// resumes, so a correctly placed mark averages in the speech that
    /// follows and reads as mid-sentence — measured against a real library, a
    /// one-second window called every boundary of a correctly cut book wrong.
    private static let windowSeconds = 0.25

    /// How long the pause before this mark had already been running.
    ///
    /// Walks back through any audio the mark itself sits on — a spoken
    /// chapter announcement is sound, and the pause that matters is the one
    /// *before* it — then measures the silence that precedes it. `nil` when
    /// speech runs continuously back to the edge of the window.
    private static func silenceRunningBack(_ samples: [Float], from offset: TimeInterval) -> TimeInterval? {
        let step = 0.1
        var position = offset

        // Skip the audio the mark is on, but only a short way: past a couple
        // of seconds this is prose, not an announcement.
        let announcementLimit = 2.5
        var skipped: TimeInterval = 0
        while position - step > 0, skipped < announcementLimit,
              rms(samples, around: position, window: 0.2) >= Result.silenceThreshold {
            position -= step
            skipped += step
        }
        guard rms(samples, around: position, window: 0.2) < Result.silenceThreshold else { return nil }

        var run: TimeInterval = 0
        while position - step > 0 {
            position -= step
            guard rms(samples, around: position, window: 0.2) < Result.silenceThreshold else { break }
            run += step
        }
        return run >= 0.2 ? run : nil
    }

    /// How soon sound resumes after the mark, or `nil` if it never went quiet.
    private static func silenceRunningForward(_ samples: [Float], from offset: TimeInterval) -> TimeInterval? {
        let step = 0.1
        let end = Double(samples.count) / sampleRate
        var position = offset
        var run: TimeInterval = 0
        while position + step < end {
            position += step
            guard rms(samples, around: position, window: 0.2) < Result.silenceThreshold else { break }
            run += step
        }
        return run >= 0.2 ? run : nil
    }

    /// Where the quietest window sits relative to the mark. Only offered for
    /// a mid-sentence mark, and only when it is genuinely quiet.
    private static func nearestPause(_ samples: [Float]) -> TimeInterval? {
        let window = Int(0.5 * sampleRate)
        let step = window / 2
        guard samples.count > window else { return nil }

        var best: (offset: TimeInterval, level: Float)?
        var index = 0
        while index + window <= samples.count {
            let sum = samples[index ..< index + window].reduce(Float(0)) { $0 + $1 * $1 }
            let level = (sum / Float(window)).squareRoot()
            if best == nil || level < best!.level {
                best = (Double(index + window / 2) / sampleRate, level)
            }
            index += step
        }
        guard let best, best.level < Result.silenceThreshold else { return nil }
        return best.offset - searchWindow
    }

    private static func samples(
        of track: AVAssetTrack, in asset: AVAsset, from start: TimeInterval, seconds: TimeInterval
    ) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, start), preferredTimescale: 600),
            duration: CMTime(seconds: seconds, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { values in
                for index in 0 ..< (length / 2) {
                    samples.append(Float(values[index]) / 32768)
                }
            }
        }
        return samples
    }

    private static func rms(_ samples: [Float], around offset: TimeInterval, window: TimeInterval? = nil) -> Float {
        let half = Int((window ?? windowSeconds) * sampleRate / 2)
        let centre = Int(offset * sampleRate)
        let range = max(0, centre - half) ..< min(samples.count, centre + half)
        guard !range.isEmpty else { return 0 }
        let sum = samples[range].reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(range.count)).squareRoot()
    }
}
