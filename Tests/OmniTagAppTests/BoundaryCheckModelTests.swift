import Foundation
import MediaCore
@testable import OmniTagApp
import TagIO
import Testing

@MainActor
@Suite("Chapter boundary check in the library model")
struct BoundaryCheckModelTests {
    private func model(chapters: [Chapter], container: ContainerFormat = .m4b) -> (LibraryModel, URL) {
        let url = URL(filePath: "/tmp/\(UUID().uuidString).\(container.rawValue)")
        let model = LibraryModel()
        model.items = [MediaItem(url: url, kind: .audiobook, container: container, chapters: chapters)]
        model.selection = [url]
        return (model, url)
    }

    @Test("nothing is offered for a file with no chapters")
    func noChaptersNoCheck() {
        let (model, _) = model(chapters: [])
        #expect(!model.canCheckBoundaries)
    }

    @Test("a single chapter is not worth checking — it starts at zero")
    func singleChapterNoCheck() {
        let (model, _) = model(chapters: [Chapter(index: 0, start: 0, title: "One")])
        #expect(!model.canCheckBoundaries)
    }

    @Test("a chaptered audio file can be checked")
    func chaptersCanBeChecked() {
        let (model, _) = model(chapters: [
            Chapter(index: 0, start: 0, title: "One"),
            Chapter(index: 1, start: 600, title: "Two")
        ])
        #expect(model.canCheckBoundaries)
    }

    /// An epub's "chapters" are a table of contents, not audio — there is no
    /// waveform to measure, and offering the check would be nonsense.
    @Test("a format with no audio is never offered the check")
    func nonAudioNotChecked() {
        let (model, _) = model(chapters: [
            Chapter(index: 0, start: 0, title: "One"),
            Chapter(index: 1, start: 600, title: "Two")
        ], container: .epub)
        #expect(!model.canCheckBoundaries)
    }

    @Test("results are keyed by chapter index so a row can find its own")
    func resultsAreLookedUpByIndex() {
        let (model, _) = model(chapters: [
            Chapter(index: 0, start: 0, title: "One"),
            Chapter(index: 1, start: 600, title: "Two")
        ])
        model.boundaryResults = [
            .init(index: 1, start: 600, level: 0, silenceBefore: 2.0, silenceAfter: 1.0, nearestPause: nil)
        ]

        #expect(model.boundaryResult(forChapter: 1) != nil)
        #expect(model.boundaryResult(forChapter: 0) == nil, "chapter 0 was not checked")
    }

    /// The one action the check offers: move a mark back to where the audio
    /// actually stopped, so the chapter does not open with dead air.
    @Test("nudging a mark moves it to the start of its pause")
    func nudgeMovesTheMark() {
        let chapters = [
            Chapter(index: 0, start: 0, title: "One"),
            Chapter(index: 1, start: 600, title: "Two")
        ]
        let result = ChapterBoundaryCheck.Result(
            index: 1, start: 600, level: 0, silenceBefore: 2.0, silenceAfter: 1.0, nearestPause: nil
        )

        let moved = LibraryModel.nudged(chapters, using: result)

        #expect(moved[1].start == 598, "2 s back, to where the audio stopped")
        #expect(moved[0].start == 0, "other chapters are untouched")
    }

    @Test("a mark is never nudged past the chapter before it")
    func nudgeStopsAtThePreviousChapter() {
        let chapters = [
            Chapter(index: 0, start: 0, title: "One"),
            Chapter(index: 1, start: 3, title: "Two")
        ]
        let result = ChapterBoundaryCheck.Result(
            index: 1, start: 3, level: 0, silenceBefore: 10, silenceAfter: 1, nearestPause: nil
        )

        let moved = LibraryModel.nudged(chapters, using: result)

        #expect(moved[1].start > 0, "it may not land on or before chapter one")
    }

    @Test("a mid-sentence mark moves to its nearest pause instead")
    func nudgeUsesNearestPause() {
        let chapters = [
            Chapter(index: 0, start: 0, title: "One"),
            Chapter(index: 1, start: 600, title: "Two")
        ]
        let result = ChapterBoundaryCheck.Result(
            index: 1, start: 600, level: 0.08, silenceBefore: nil, silenceAfter: nil, nearestPause: 2.5
        )

        let moved = LibraryModel.nudged(chapters, using: result)

        #expect(moved[1].start == 602.5)
    }

    @Test("a mark with nothing to correct is left exactly where it is")
    func nudgeDoesNothingWhenCorrect() {
        let chapters = [
            Chapter(index: 0, start: 0, title: "One"),
            Chapter(index: 1, start: 600, title: "Two")
        ]
        let result = ChapterBoundaryCheck.Result(
            index: 1, start: 600, level: 0, silenceBefore: 0.3, silenceAfter: 1, nearestPause: nil
        )

        #expect(LibraryModel.nudged(chapters, using: result)[1].start == 600)
    }

    /// Selecting another file must not leave the previous file's verdicts on
    /// screen — they would be attributed to chapters they never described.
    @Test("changing the selection clears stale results")
    func selectionClearsResults() {
        let (model, _) = model(chapters: [
            Chapter(index: 0, start: 0, title: "One"),
            Chapter(index: 1, start: 600, title: "Two")
        ])
        model.boundaryResults = [
            .init(index: 1, start: 600, level: 0, silenceBefore: 2.0, silenceAfter: 1.0, nearestPause: nil)
        ]

        model.selection = []

        #expect(model.boundaryResults.isEmpty)
    }
}
