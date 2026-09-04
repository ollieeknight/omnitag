import AVFoundation
import Foundation
import MediaCore
@testable import TagIO
import Testing

/// Built from generated audio: tone, silence, tone — so a boundary's real
/// position is known exactly and the check can be judged against it.
@Suite("Chapter boundary check")
struct ChapterBoundaryCheckTests {
    /// 30 seconds of 440 Hz tone with one second of digital silence centred
    /// at 15 s — the shape of a real chapter break.
    private func makeAudio(
        silenceAt gap: Double = 15, silenceWidth: Double = 1,
        shape: ((Double) -> Bool)? = nil
    ) throws -> (URL, FixtureLibrary) {
        let library = try FixtureLibrary()
        let wav = library.root.appending(path: "boundary.wav")
        let rate = 8000.0
        let total = Int(30 * rate)

        var samples = [Int16](repeating: 0, count: total)
        for index in 0 ..< total {
            let seconds = Double(index) / rate
            let sounding = shape.map { $0(seconds) } ?? (abs(seconds - gap) >= silenceWidth / 2)
            let silent = !sounding
            samples[index] = silent ? 0 : Int16(12000 * sin(2 * .pi * 440 * seconds))
        }

        var data = Data()
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        for sample in samples {
            append(sample)
        }
        try data.write(to: wav)
        return (wav, library)
    }

    /// Tone, pause, a short burst, pause, tone — the shape of a spoken
    /// chapter announcement sitting between two silences.
    private func makeBurstAudio() throws -> (URL, FixtureLibrary) {
        try makeAudio(shape: { seconds in
            if seconds >= 15.0, seconds < 15.8 {
                return true
            } // the announcement
            if seconds >= 13.0, seconds < 17.5 {
                return false
            } // pauses either side
            return true
        })
    }

    @Test("a mark at a pause is described as such, and is not called mid-sentence")
    func markInAPause() async throws {
        let (url, library) = try makeAudio()
        defer { _ = library }

        let results = try await ChapterBoundaryCheck.check(
            [Chapter(index: 0, start: 0, title: "One"), Chapter(index: 1, start: 15, title: "Two")], in: url
        )

        let boundary = try #require(results.first)
        #expect(!boundary.isMidSentence)
        #expect(boundary.silenceAfter != nil, "sound resumes shortly after")
    }

    /// The Horus Rising shape: the mark sits two seconds into a long pause,
    /// so every skip replays dead air. Reported, but not called a fault —
    /// the summary says how far back the audio stopped and lets the user judge.
    @Test("a mark buried in a long gap reports how long the pause had already run")
    func markInsideALongGap() async throws {
        let (url, library) = try makeAudio(silenceAt: 15.5, silenceWidth: 5)
        defer { _ = library }

        let results = try await ChapterBoundaryCheck.check(
            [Chapter(index: 1, start: 17.0, title: "Two")], in: url
        )

        let boundary = try #require(results.first)
        #expect(!boundary.isMidSentence, "it is in a pause, not mid-sentence")
        let before = try #require(boundary.silenceBefore)
        #expect(before > 1.5, "the pause had already run ~3 s; got \(before)")
        #expect(boundary.summary.contains("after the previous audio ended"))
    }

    /// The A Thousand Sons shape: prose, a pause, a spoken "Chapter Two", a
    /// pause, then prose — with the mark deliberately on the announcement.
    /// Calling that wrong would teach the user to ignore the checker.
    @Test("a mark on a chapter announcement is not called a fault")
    func markOnAnAnnouncement() async throws {
        let (url, library) = try makeBurstAudio()
        defer { _ = library }

        // The burst runs 15.0–15.8 s, with pauses either side.
        let results = try await ChapterBoundaryCheck.check(
            [Chapter(index: 1, start: 15.3, title: "Two")], in: url
        )

        let boundary = try #require(results.first)
        #expect(!boundary.isMidSentence, "it is deliberate audio between two pauses")
        #expect(boundary.summary.contains("announcement"))
    }

    @Test("a mark in continuous speech is the one thing called a fault")
    func midSentenceIsFlagged() async throws {
        let (url, library) = try makeAudio(silenceAt: 28)
        defer { _ = library }

        let results = try await ChapterBoundaryCheck.check([Chapter(index: 1, start: 5, title: "Two")], in: url)

        let boundary = try #require(results.first)
        #expect(boundary.isMidSentence)
        #expect(boundary.summary.contains("Mid-sentence"))
    }

    @Test("the first chapter is not checked — it starts at zero by definition")
    func firstChapterSkipped() async throws {
        let (url, library) = try makeAudio()
        defer { _ = library }

        #expect(try await ChapterBoundaryCheck.check([Chapter(index: 0, start: 0, title: "One")], in: url).isEmpty)
    }

    @Test("a file with no audio track answers empty rather than failing")
    func noAudioTrack() async throws {
        let library = try FixtureLibrary()
        let text = library.root.appending(path: "notaudio.txt")
        try Data("nope".utf8).write(to: text)

        #expect(try await ChapterBoundaryCheck.check([Chapter(index: 1, start: 5, title: "x")], in: text).isEmpty)
    }
}
