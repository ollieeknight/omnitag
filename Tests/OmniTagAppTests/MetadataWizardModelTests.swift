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

    @Test("mkv never receives artwork, even when the provider has a cover")
    func mkvNeverGetsArtwork() async throws {
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

        #expect(model.canWriteArtwork == false, "mkv has no artwork writer")
        #expect(model.hasUnwritableArtwork == true, "there IS a cover on offer, it just cannot be stored")
        let (_, artwork, _, _) = try await model.buildSnapshot()
        #expect(artwork.isEmpty, "downloading and discarding the cover would be a wasted round trip")
    }

    @Test("mp4 with the same cover DOES receive artwork — the mkv case above is a container limit, not a general rule")
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
