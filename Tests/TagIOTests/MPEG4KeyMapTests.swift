import AVFoundation
import Foundation
import MediaCore
@testable import TagIO
import Testing

@Suite("MPEG4KeyMap")
struct MPEG4KeyMapTests {
    private func makeItem(identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(identifier)
        return item
    }

    @Test("recognises freeform tags across arbitrary mean namespaces (Libation/Tone)")
    func matchesArbitraryMean() {
        let series = makeItem(identifier: "itlk/com.pilabor.tone.SERIES")
        #expect(MPEG4KeyMap.key(for: series) == .series)

        let subtitle = makeItem(identifier: "itlk/com.pilabor.tone.SUBTITLE")
        #expect(MPEG4KeyMap.key(for: subtitle) == .subtitle)

        let language = makeItem(identifier: "itlk/com.pilabor.tone.LANGUAGE")
        #expect(MPEG4KeyMap.key(for: language) == .language)

        let part = makeItem(identifier: "itlk/com.pilabor.tone.SERIES-PART")
        #expect(MPEG4KeyMap.key(for: part) == .seriesIndex)
    }

    @Test("matches freeform tags case-insensitively and recognises freeform GENRE")
    func matchesCaseInsensitiveAndGenre() {
        let genreUpper = makeItem(identifier: "itlk/com.apple.iTunes.GENRE")
        #expect(MPEG4KeyMap.key(for: genreUpper) == .genre)

        let genreTone = makeItem(identifier: "itlk/com.pilabor.tone.genre")
        #expect(MPEG4KeyMap.key(for: genreTone) == .genre)

        let seriesLower = makeItem(identifier: "itlk/com.apple.iTunes.series")
        #expect(MPEG4KeyMap.key(for: seriesLower) == .series)
    }

    @Test("reads FourCC asin atom without changing write target")
    func readsFourCCAsin() {
        let asinAtom = makeItem(identifier: "itsk/asin")
        #expect(MPEG4KeyMap.key(for: asinAtom) == .asin)

        // Writing .asin must still target canonical freeform under com.apple.iTunes
        let writeID = MPEG4KeyMap.identifier(for: .asin)
        #expect(writeID?.rawValue == "itlk/com.apple.iTunes.ASIN")
    }

    @Test("ignores Apple machine state atom iTunSMPB")
    func ignoresGaplessAtom() {
        let gapless = makeItem(identifier: "itlk/com.apple.iTunes.iTunSMPB")
        #expect(MPEG4KeyMap.key(for: gapless) == nil)
    }

    @Test("tmdbID has a write target, like every other video key")
    func tmdbIDHasWriteTarget() {
        // Every other movie/TV key (.director, .studio, .contentRating, .showName,
        // .seasonNumber, .episodeNumber, .episodeTitle) has an atom or freeform
        // mapping. .tmdbID was added to TagKey but never wired into the map, so
        // MPEG4TagWriter's `guard let identifier = ... else { continue }` silently
        // drops it on write — see MPEG4TagWriter.swift.
        #expect(MPEG4KeyMap.identifier(for: .tmdbID) != nil,
                ".tmdbID has no atom/freeform mapping, so it is silently dropped on write")
    }
}

@Suite("AVTagReader Fallbacks")
struct AVTagReaderFallbackTests {
    @Test("falls back to composer for narrator when narrator is absent")
    func narratorFallback() async throws {
        let library = try FixtureLibrary()
        let url = try await library.makeTagged(TwinPeaks.theme)

        let item = try await AVTagReader().read(url)
        #expect(item.tags[.narrator] == .string("Angelo Badalamenti"))
    }

    @Test("does not override existing narrator with composer")
    func narratorPreserved() async throws {
        let library = try FixtureLibrary()
        let url = try await library.makeTagged(TwinPeaks.diary)
        var edited = TwinPeaks.diary.tags
        edited[.composer] = .string("Different Composer")
        try await MPEG4TagWriter().write(edited, to: url)

        let item = try await AVTagReader().read(url)
        #expect(item.tags[.narrator] == .string("Eliza Dushku"))
        #expect(item.tags[.composer] == .string("Different Composer"))
    }

    @Test("falls back to albumArtist or artist for author when author is absent")
    func authorFallback() async throws {
        let library = try FixtureLibrary()
        let url = try await library.makeTagged(TwinPeaks.theme)

        let item = try await AVTagReader().read(url)
        #expect(item.tags[.author] == .string("Angelo Badalamenti"))
    }
}
