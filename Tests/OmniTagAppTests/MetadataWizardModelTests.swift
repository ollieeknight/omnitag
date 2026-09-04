import Foundation
import MediaCore
@testable import MetadataAPI
@testable import OmniTagApp
import Testing

/// Returns canned candidates/details so the model can be driven without a
/// network. Mirrors the movie/TV or audiobook shape depending on `kind`.
private struct FakeProvider: MetadataProvider {
    var id: String
    var name = "Fake"
    var kinds: Set<MediaKind>
    var searchHint = "Search"
    var hasEpisodePicker = false
    var isMissingAPIKey = false
    var candidatesToReturn: [MetadataCandidate] = []
    var detailsToReturn: MetadataDetails?

    func search(_ query: MetadataQuery, kind: MediaKind, limit: Int) async throws -> [MetadataCandidate] {
        candidatesToReturn
    }

    func details(for candidate: MetadataCandidate, kind: MediaKind) async throws -> MetadataDetails {
        guard let detailsToReturn else { throw MetadataError.emptyQuery }
        return detailsToReturn
    }
}

private func makeItem(
    container: ContainerFormat = .m4b, kind: MediaKind = .audiobook,
    tags: TagSet = TagSet(), chapters: [Chapter] = []
) -> MediaItem {
    MediaItem(
        url: URL(filePath: "/tmp/\(UUID().uuidString).\(container.rawValue)"),
        kind: kind, container: container, tags: tags, chapters: chapters
    )
}

@MainActor
private func makeModel(
    items: [MediaItem], kind: MediaKind, provider: FakeProvider
) -> MetadataWizardModel {
    let model = MetadataWizardModel(items: items, kind: kind)
    model.provider = provider
    return model
}

@MainActor
@Suite("MetadataWizardModel.buildSnapshot")
struct BuildSnapshotTests {
    @Test("skipping chapters means the snapshot writes nil, not an empty list")
    func skippedChaptersAreNil() async throws {
        let details = MetadataDetails(
            book: MetadataRecord(id: "1", title: "Fire Walk with Me", kind: .movie),
            chapters: [Chapter(index: 0, start: 0, title: "Ch 1")]
        )
        let provider = FakeProvider(id: "fake", kinds: [.movie], detailsToReturn: details)
        let item = makeItem(container: .mkv, kind: .movie)
        let model = makeModel(items: [item], kind: .movie, provider: provider)

        await model.select(candidate: MetadataCandidate(id: "1", title: "Fire Walk with Me", authors: [], narrators: []))
        model.skipChapters = true

        let (_, _, chapters, _) = try await model.buildSnapshot()
        #expect(chapters == nil, "skipChapters must suppress the write, not send an empty chapter list that erases the file's own")
    }

    @Test("a multi-file selection never writes chapters, even if the provider has them")
    func multiFileNeverWritesChapters() async throws {
        let details = MetadataDetails(
            book: MetadataRecord(id: "1", title: "Some Book", kind: .audiobook),
            chapters: [Chapter(index: 0, start: 0, title: "Ch 1"), Chapter(index: 1, start: 60, title: "Ch 2")]
        )
        let provider = FakeProvider(id: "fake", kinds: [.audiobook], detailsToReturn: details)
        let items = [makeItem(), makeItem()]
        let model = makeModel(items: items, kind: .audiobook, provider: provider)

        await model.select(candidate: MetadataCandidate(id: "1", title: "Some Book", authors: [], narrators: []))
        model.skipChapters = false // an explicit "please write them" that must still be refused

        #expect(model.canWriteChapters == false)
        let (_, _, chapters, _) = try await model.buildSnapshot()
        #expect(chapters == nil, "one book's chapters must never fan out across a multi-file selection")
    }

    @Test("mkv receives artwork now that MatroskaTagWriter writes AttachedFile covers")
    func mkvGetsArtwork() async {
        let details = MetadataDetails(
            book: MetadataRecord(
                id: "603", title: "The Matrix", artworkURL: URL(string: "https://example.com/poster.jpg"),
                kind: .movie
            ),
            chapters: []
        )
        let provider = FakeProvider(id: "tmdb", kinds: [.movie], detailsToReturn: details)
        let item = makeItem(container: .mkv, kind: .movie)
        let model = makeModel(items: [item], kind: .movie, provider: provider)

        await model.select(
            candidate: MetadataCandidate(
                id: "603", title: "The Matrix", authors: [], narrators: [],
                artworkURL: URL(string: "https://example.com/poster.jpg")
            )
        )

        #expect(model.canWriteArtwork == true)
        #expect(model.hasUnwritableArtwork == false)
    }

    @Test("mp4 with the same cover DOES receive artwork — same as the mkv case above, not a container-specific rule")
    func mp4DoesGetArtwork() async {
        let details = MetadataDetails(
            book: MetadataRecord(
                id: "603", title: "The Matrix", artworkURL: URL(string: "https://example.com/poster.jpg"),
                kind: .movie
            ),
            chapters: []
        )
        let provider = FakeProvider(id: "tmdb", kinds: [.movie], detailsToReturn: details)
        let item = makeItem(container: .mp4, kind: .movie)
        let model = makeModel(items: [item], kind: .movie, provider: provider)

        await model.select(
            candidate: MetadataCandidate(
                id: "603", title: "The Matrix", authors: [], narrators: [],
                artworkURL: URL(string: "https://example.com/poster.jpg")
            )
        )

        #expect(model.canWriteArtwork == true)
        #expect(model.hasUnwritableArtwork == false)
    }

    @Test("clean overwrite off means nothing is cleared, even if the provider omits a field the file has")
    func mergeModeNeverClears() async throws {
        var currentTags = TagSet()
        currentTags[.director] = .string("Someone")
        let details = MetadataDetails(book: MetadataRecord(id: "1", title: "T", kind: .movie), chapters: [])
        let provider = FakeProvider(id: "fake", kinds: [.movie], detailsToReturn: details)
        let item = makeItem(container: .mp4, kind: .movie, tags: currentTags)
        let model = makeModel(items: [item], kind: .movie, provider: provider)

        await model.select(candidate: MetadataCandidate(id: "1", title: "T", authors: [], narrators: []))
        model.apply(.merge)

        let (_, _, _, clearing) = try await model.buildSnapshot()
        #expect(clearing.isEmpty, "merge mode must never remove a field the provider simply didn't mention")
    }
}

@MainActor
@Suite("MetadataWizardModel guards against multi-file misapplication")
struct MultiFileGuardTests {
    @Test("canWriteChapters is false for more than one file")
    func chaptersGuard() {
        let model = MetadataWizardModel(items: [makeItem(), makeItem()], kind: .audiobook)
        #expect(model.canWriteChapters == false)
    }

    @Test("canPickEpisode is false for more than one file")
    func episodeGuard() {
        let model = MetadataWizardModel(items: [makeItem(container: .mkv, kind: .tvEpisode), makeItem(container: .mkv, kind: .tvEpisode)], kind: .tvEpisode)
        #expect(model.canPickEpisode == false)
    }

    @Test("a TV multi-file selection skips the episode step even with an episode-picker provider")
    func multiFileTVSkipsEpisodeStep() async {
        let showDetails = MetadataDetails(book: MetadataRecord(id: "1622", title: "Twin Peaks", kind: .tvEpisode), chapters: [])
        // hasEpisodePicker is true here on purpose: this proves the multi-file
        // guard (canPickEpisode), not the absence of a picker-capable
        // provider, is what keeps the episode step out of `steps`.
        let provider = FakeProvider(id: "tmdb", kinds: [.tvEpisode], hasEpisodePicker: true, detailsToReturn: showDetails)
        let items = [makeItem(container: .mkv, kind: .tvEpisode), makeItem(container: .mkv, kind: .tvEpisode)]
        let model = makeModel(items: items, kind: .tvEpisode, provider: provider)

        await model.select(candidate: MetadataCandidate(id: "1622", title: "Twin Peaks", authors: [], narrators: []))

        #expect(model.isEpisodeFlow == false)
        #expect(model.steps.contains(.episode) == false)
        #expect(model.step == .tags)
    }
}

@MainActor
@Suite("MetadataWizardModel TV episode selection")
struct EpisodeSelectionTests {
    @Test("a single-file TV selection with an episode-picker provider lands on the episode step, not the tag diff")
    func singleFileLandsOnEpisodeStep() async {
        let showDetails = MetadataDetails(book: MetadataRecord(id: "1622", title: "Twin Peaks", kind: .tvEpisode), chapters: [])
        let provider = FakeProvider(id: "fake-tmdb", kinds: [.tvEpisode], hasEpisodePicker: true, detailsToReturn: showDetails)
        let item = makeItem(container: .mkv, kind: .tvEpisode)
        let model = makeModel(items: [item], kind: .tvEpisode, provider: provider)

        await model.select(candidate: MetadataCandidate(id: "1622", title: "Twin Peaks", authors: [], narrators: []))

        #expect(model.step == .episode, "a show candidate must not fall through to building a tag diff against show-level data")
        #expect(model.isEpisodeFlow == true)
        #expect(model.steps.contains(.episode) == true)
        #expect(
            model.tagDiff.rows.allSatisfy { $0.proposed == nil },
            "no proposed values should exist yet — nobody asked to write the show's own fields"
        )
    }

    @Test("a provider without hasEpisodePicker never routes to the episode step, even for tvEpisode kind")
    func nonPickerProviderSkipsEpisodeStep() async {
        let details = MetadataDetails(book: MetadataRecord(id: "1", title: "Some Episode", kind: .tvEpisode), chapters: [])
        let provider = FakeProvider(id: "fake", kinds: [.tvEpisode], hasEpisodePicker: false, detailsToReturn: details)
        let item = makeItem(container: .mkv, kind: .tvEpisode)
        let model = makeModel(items: [item], kind: .tvEpisode, provider: provider)

        await model.select(candidate: MetadataCandidate(id: "1", title: "Some Episode", authors: [], narrators: []))

        #expect(model.step == .tags)
        #expect(model.isEpisodeFlow == false)
    }

    @Test("Back from Tags after picking an episode returns to the episode step, not Search")
    func backAfterPickingEpisodeReturnsToEpisodeStep() async {
        // The bug this guards against: `.episode` used to be removed from
        // `steps` the moment an episode was picked, so `retreat()` from
        // `.tags` skipped straight to `.search` — silently losing the
        // chosen show and episode. See docs/MOVIES_TV.md.
        let showDetails = MetadataDetails(book: MetadataRecord(id: "1622", title: "Twin Peaks", kind: .tvEpisode), chapters: [])
        let provider = FakeProvider(id: "fake-tmdb", kinds: [.tvEpisode], hasEpisodePicker: true, detailsToReturn: showDetails)
        let item = makeItem(container: .mkv, kind: .tvEpisode)
        let model = makeModel(items: [item], kind: .tvEpisode, provider: provider)

        await model.select(candidate: MetadataCandidate(id: "1622", title: "Twin Peaks", authors: [], narrators: []))
        #expect(model.step == .episode)

        // selectEpisode needs a real TMDBProvider to resolve; simulate having
        // already picked one by driving the model to `.tags` the way
        // `selectEpisode` does, then exercise retreat() from there.
        model.step = .tags

        model.retreat()

        #expect(model.step == .episode, "Back must return to the episode picker, not skip to Search")
    }
}

@MainActor
@Suite("TV episode picker state")
struct EpisodePickerStateTests {
    private func tvModel() -> (MetadataWizardModel, FakeProvider) {
        let details = MetadataDetails(
            book: MetadataRecord(id: "1622", title: "Twin Peaks", kind: .tvEpisode), chapters: []
        )
        let provider = FakeProvider(
            id: "fake-tv", kinds: [.tvEpisode], hasEpisodePicker: true, detailsToReturn: details
        )
        let item = makeItem(container: .mkv, kind: .tvEpisode)
        return (makeModel(items: [item], kind: .tvEpisode, provider: provider), provider)
    }

    @Test("picking a second show resets the season list rather than showing the first show's episodes")
    func staleEpisodesAreCleared() async {
        let (model, _) = tvModel()
        model.episodeLoadState = .loaded([
            TMDBClient.EpisodeSummary(number: 1, title: "Northwest Passage", airDate: "1990-04-08")
        ])

        await model.select(candidate: MetadataCandidate(id: "1622", title: "Twin Peaks", authors: [], narrators: []))

        // The fake provider is not a TMDBProvider, so loadSeasonEpisodes is a
        // no-op here — which is exactly the window in which a stale list from
        // the previously-picked show would still be on screen.
        if case let .loaded(episodes) = model.episodeLoadState {
            Issue.record("stale episode list survived: \(episodes)")
        }
    }

    @Test("a new show starts at season 1")
    func seasonResetsForANewShow() async {
        let (model, _) = tvModel()
        model.selectedSeason = 4

        await model.select(candidate: MetadataCandidate(id: "1622", title: "Twin Peaks", authors: [], narrators: []))

        #expect(model.selectedSeason == 1)
    }
}

@MainActor
@Suite("Episode picker opens where the filename points")
struct EpisodePrefillTests {
    @Test("a file named SxxEyy opens the picker on its own season")
    func seasonComesFromTheFilename() async {
        let details = MetadataDetails(
            book: MetadataRecord(id: "1622", title: "Twin Peaks", kind: .tvEpisode), chapters: []
        )
        let provider = FakeProvider(
            id: "fake-tv", kinds: [.tvEpisode], hasEpisodePicker: true, detailsToReturn: details
        )
        let item = MediaItem(
            url: URL(filePath: "/tmp/Twin.Peaks.S02E07.mkv"),
            kind: .tvEpisode, container: .mkv, tags: TagSet(), chapters: []
        )
        let model = makeModel(items: [item], kind: .tvEpisode, provider: provider)
        #expect(model.query.season == 2)

        await model.select(candidate: MetadataCandidate(id: "1622", title: "Twin Peaks", authors: [], narrators: []))

        // Season 1 would make the user hunt for a season the filename already named.
        #expect(model.selectedSeason == 2)
        #expect(model.suggestedEpisode == 7)
    }

    @Test("a file with no episode marker still opens on season 1")
    func unmarkedFileDefaultsToSeasonOne() async {
        let details = MetadataDetails(
            book: MetadataRecord(id: "1622", title: "Twin Peaks", kind: .tvEpisode), chapters: []
        )
        let provider = FakeProvider(
            id: "fake-tv", kinds: [.tvEpisode], hasEpisodePicker: true, detailsToReturn: details
        )
        let item = makeItem(container: .mkv, kind: .tvEpisode)
        let model = makeModel(items: [item], kind: .tvEpisode, provider: provider)

        await model.select(candidate: MetadataCandidate(id: "1622", title: "Twin Peaks", authors: [], narrators: []))

        #expect(model.selectedSeason == 1)
        #expect(model.suggestedEpisode == nil)
    }
}

@MainActor
@Suite("Missing API key")
struct MissingKeyTests {
    @Test("a provider with no key says so before a search is typed")
    func keyGapIsVisibleUpFront() {
        let provider = FakeProvider(id: "fake", kinds: [.movie], isMissingAPIKey: true)
        let model = makeModel(items: [makeItem(container: .mkv, kind: .movie)], kind: .movie, provider: provider)

        #expect(model.needsAPIKey)
    }

    @Test("a provider that needs no key never shows the notice")
    func keylessProviderIsQuiet() {
        let provider = FakeProvider(id: "fake", kinds: [.audiobook])
        let model = makeModel(items: [makeItem()], kind: .audiobook, provider: provider)

        #expect(!model.needsAPIKey)
        // And the audiobook wording is the only place the Audible link is mentioned.
        #expect(!model.searchPrompt.contains("Audible"))
    }
}

@Suite("Rename presets")
struct RenamePresetTests {
    /// A tag set rich enough for every preset of every kind to render.
    private var tags: TagSet {
        var tags = TagSet()
        tags[.title] = .string("Northwest Passage")
        tags[.artist] = .string("Angelo Badalamenti")
        tags[.album] = .string("Twin Peaks")
        tags[.trackNumber] = .number(1)
        tags[.author] = .string("Jennifer Lynch")
        tags[.series] = .string("Twin Peaks")
        tags[.seriesIndex] = .number(1)
        tags[.showName] = .string("Twin Peaks")
        tags[.seasonNumber] = .number(1)
        tags[.episodeNumber] = .number(1)
        tags[.episodeTitle] = .string("Northwest Passage")
        tags[.year] = .number(1990)
        tags[.director] = .string("David Lynch")
        return tags
    }

    @Test("every preset renders a name and parses back the fields it names", arguments: MediaKind.allCases)
    func presetsRoundTrip(kind: MediaKind) throws {
        for preset in RenameSheet.presets(for: kind) {
            let pattern = FilenamePattern(preset)
            let rendered = pattern.render(tags)
            #expect(rendered.missing.isEmpty, "\(preset) wanted fields the tag set has: \(rendered.missing)")
            #expect(!rendered.name.isEmpty, "\(preset) rendered nothing")

            let parsed = try #require(
                pattern.parse(rendered.name), "\(preset) could not parse back \"\(rendered.name)\""
            )
            for key in pattern.fields {
                #expect(parsed[key] == tags[key], "\(preset): \(key) did not survive the round trip")
            }
        }
    }
}

@MainActor
@Suite("Music: one track's fields never land on a whole album")
struct MusicMultiFileTests {
    private func musicDetails() -> MetadataDetails {
        MetadataDetails(
            book: MetadataRecord(
                id: "600015397", title: "Twin Peaks Theme", authors: ["Angelo Badalamenti"],
                year: 1990, genres: ["Soundtrack"],
                album: "Twin Peaks (Soundtrack From)", albumArtist: "Angelo Badalamenti",
                trackNumber: 1, trackTotal: 11, discNumber: 1, discTotal: 1, kind: .music
            ),
            chapters: []
        )
    }

    private func model(fileCount: Int) -> MetadataWizardModel {
        let provider = FakeProvider(id: "itunes", kinds: [.music], detailsToReturn: musicDetails())
        let items = (0 ..< fileCount).map { _ in makeItem(container: .mp3, kind: .music) }
        return makeModel(items: items, kind: .music, provider: provider)
    }

    @Test("one file gets everything, track number and title included")
    func singleFileGetsTrackFields() async throws {
        let model = model(fileCount: 1)
        await model.select(candidate: MetadataCandidate(id: "1", title: "Twin Peaks Theme", authors: [], narrators: []))

        let (tags, _, _, _) = try await model.buildSnapshot()

        #expect(tags[.title]?.stringValue == "Twin Peaks Theme")
        #expect(tags[.trackNumber]?.intValue == 1)
        #expect(tags[.album]?.stringValue == "Twin Peaks (Soundtrack From)")
    }

    /// The exact bug the TV episode picker exists to prevent, in its music
    /// form: one song's title and number written onto every file of an album.
    @Test("a multi-file selection gets album fields but never one track's title or number")
    func multiFileSkipsTrackFields() async throws {
        let model = model(fileCount: 5)
        await model.select(candidate: MetadataCandidate(id: "1", title: "Twin Peaks Theme", authors: [], narrators: []))

        let (tags, _, _, _) = try await model.buildSnapshot()

        #expect(tags[.album]?.stringValue == "Twin Peaks (Soundtrack From)", "the album is shared")
        #expect(tags[.artist]?.stringValue == "Angelo Badalamenti")
        #expect(tags[.year]?.intValue == 1990)
        #expect(tags[.genre]?.stringValue == "Soundtrack")

        #expect(tags[.title] == nil, "one song's title cannot be right for five files")
        #expect(tags[.trackNumber] == nil, "nor its track number")
    }

    @Test("the per-track rows are not merely unticked — they are not offered")
    func trackRowsAreAbsentForAMultiSelection() async {
        let model = model(fileCount: 5)
        await model.select(candidate: MetadataCandidate(id: "1", title: "Twin Peaks Theme", authors: [], narrators: []))

        // A row the user could tick would put the wrong title back.
        let offered = model.tagDiff.rows.filter { $0.proposed != nil }.map(\.key)
        #expect(!offered.contains(.title))
        #expect(!offered.contains(.trackNumber))
        #expect(offered.contains(.album))
    }

    @Test("a non-music kind is unaffected by the album guard")
    func otherKindsKeepTheirTitle() async throws {
        let details = MetadataDetails(
            book: MetadataRecord(id: "1", title: "Fire Walk with Me", kind: .movie), chapters: []
        )
        let provider = FakeProvider(id: "tmdb", kinds: [.movie], detailsToReturn: details)
        let items = [makeItem(container: .mkv, kind: .movie), makeItem(container: .mkv, kind: .movie)]
        let model = makeModel(items: items, kind: .movie, provider: provider)

        await model.select(candidate: MetadataCandidate(id: "1", title: "Fire Walk with Me", authors: [], narrators: []))
        let (tags, _, _, _) = try await model.buildSnapshot()

        #expect(tags[.title]?.stringValue == "Fire Walk with Me", "two films can share a title write")
    }
}

@MainActor
@Suite("The wizard's own movie-vs-TV choice")
struct WizardKindChoiceTests {
    private func videoModel(kind: MediaKind, files: Int = 1) -> MetadataWizardModel {
        let details = MetadataDetails(
            book: MetadataRecord(id: "1", title: "Twin Peaks", kind: kind), chapters: []
        )
        let provider = FakeProvider(
            id: "tmdb", kinds: [.movie, .tvEpisode], hasEpisodePicker: true, detailsToReturn: details
        )
        let items = (0 ..< files).map { _ in makeItem(container: .mkv, kind: kind) }
        return makeModel(items: items, kind: kind, provider: provider)
    }

    @Test("the choice is offered for video, and only for video")
    func offeredForVideoOnly() {
        #expect(videoModel(kind: .movie).offersKindChoice)
        #expect(videoModel(kind: .tvEpisode).offersKindChoice)

        let audiobook = makeModel(
            items: [makeItem()], kind: .audiobook,
            provider: FakeProvider(id: "audible", kinds: [.audiobook])
        )
        #expect(!audiobook.offersKindChoice, "a book is not a film")
    }

    @Test("switching kind changes what the wizard searches for")
    func switchingChangesTheKind() {
        let model = videoModel(kind: .movie)
        #expect(model.kind == .movie)

        model.kind = .tvEpisode

        #expect(model.kind == .tvEpisode)
    }

    /// TMDB's movie and TV searches are different endpoints, so results from
    /// one are meaningless under the other.
    @Test("switching kind clears results that no longer apply")
    func switchingClearsResults() async {
        let model = videoModel(kind: .movie)
        await model.search()
        model.searchState = .results([MetadataCandidate(id: "1", title: "Twin Peaks", authors: [], narrators: [])])

        model.kind = .tvEpisode

        if case .results = model.searchState {
            Issue.record("stale movie results survived the switch to TV")
        }
    }

    @Test("switching kind after picking a candidate returns to the search step")
    func switchingReturnsToSearch() async {
        let model = videoModel(kind: .tvEpisode)
        await model.select(candidate: MetadataCandidate(id: "1", title: "Twin Peaks", authors: [], narrators: []))
        #expect(model.step == .episode)

        model.kind = .movie

        #expect(model.step == .search, "the picked show belongs to a search that no longer applies")
        #expect(!model.isEpisodeFlow, "and its episode flow is gone with it")
    }

    @Test("setting the same kind again changes nothing")
    func settingSameKindIsInert() {
        let model = videoModel(kind: .movie)
        model.searchState = .results([MetadataCandidate(id: "1", title: "x", authors: [], narrators: [])])

        model.kind = .movie

        if case .results = model.searchState {} else {
            Issue.record("an inert set threw away the results")
        }
    }

    // MARK: write-back

    @Test("a file already of the chosen kind needs no reclassification")
    func noReclassificationWhenAgreed() {
        let model = videoModel(kind: .movie)
        #expect(model.reclassifiedKind == nil)
    }

    /// The point of the whole item: a file must not leave the wizard tagged
    /// as one kind while the library files it as another.
    @Test("choosing a different kind reclassifies the file on apply")
    func reclassifiesOnApply() {
        let model = videoModel(kind: .movie)

        model.kind = .tvEpisode

        #expect(model.reclassifiedKind == .tvEpisode)
    }

    @Test("a mixed selection is reclassified to the chosen kind as a whole")
    func mixedSelectionReclassified() {
        let details = MetadataDetails(book: MetadataRecord(id: "1", title: "x", kind: .movie), chapters: [])
        let provider = FakeProvider(id: "tmdb", kinds: [.movie, .tvEpisode], detailsToReturn: details)
        let model = makeModel(
            items: [makeItem(container: .mkv, kind: .movie), makeItem(container: .mkv, kind: .tvEpisode)],
            kind: .movie, provider: provider
        )

        #expect(model.reclassifiedKind == .movie, "the TV file disagrees, so the choice applies")
    }
}
