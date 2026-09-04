import Foundation
import MediaCore
@testable import MetadataAPI
import Testing

/// Cases drawn from the developer's real Horus Heresy library, where the
/// original heuristics silently mis-classified nine books. The titles are
/// reproduced here so the suite keeps testing them without the files.
@Suite("Chapter title heuristics")
struct ChapterTitleHeuristicTests {
    private func chapters(_ titles: [String]) -> [Chapter] {
        titles.enumerated().map { Chapter(index: $0.offset, start: Double($0.offset) * 600, title: $0.element) }
    }

    // MARK: what counts as generic

    @Test("plain numbering is generic", arguments: [
        "Chapter 1", "chapter 12", "Track 3", "Part 4", "Section 2", "7", "", "   "
    ])
    func genericTitles(title: String) {
        #expect(ChapterDiff.isGeneric(title: title))
    }

    /// `Part I` and `Book II` were judged generic because "part" and "book"
    /// were in the generic-word list — but in Fulgrim and Angel Exterminatus
    /// they are the *only* structural markers the file has.
    @Test("a Roman-numeralled part or book is real, not generic", arguments: [
        "Part I", "Part V", "Book I", "Book II", "Part IX"
    ])
    func romanPartsAreReal(title: String) {
        #expect(!ChapterDiff.isGeneric(title: title))
    }

    @Test("a named part keeps its name", arguments: [
        "Part I - Reptile Summer", "Part Two: Plague Moon", "Caliban - Chapter 1", "Soulforge Chapter 1"
    ])
    func namedPartsAreReal(title: String) {
        #expect(!ChapterDiff.isGeneric(title: title))
    }

    @Test("real titles from the library are never called generic", arguments: [
        "Melchior", "Ullanor", "Nikaea", "Harvest", "Cargo", "Choir",
        "Blood Games", "The Last Church", "Prelude", "Adenda"
    ])
    func realTitles(title: String) {
        #expect(!ChapterDiff.isGeneric(title: title))
    }

    // MARK: what deserves protecting

    /// The old rule needed 20% of titles to be real. Three real titles among
    /// 28 generic ones scored 11% and were silently overwritten — but those
    /// three are exactly the ones that cannot be recovered.
    @Test("even one real title is worth protecting")
    func oneRealTitleProtects() {
        var titles = (1 ... 28).map { "Chapter \($0)" }
        titles[0] = "Melchior"

        #expect(ChapterDiff.hasRichTitles(chapters(titles)))
    }

    @Test("Fear to Tread's three real titles among twenty-four are protected")
    func fearToTread() {
        var titles = (1 ... 24).map { "Chapter \($0)" }
        titles[0] = "Melchior"
        titles[8] = "Ullanor"
        titles[15] = "Nikaea"

        #expect(ChapterDiff.hasRichTitles(chapters(titles)))
    }

    @Test("Fulgrim's Roman-numeral parts are protected")
    func fulgrim() {
        var titles = (1 ... 26).map { "Chapter \($0)" }
        for (offset, part) in ["Part I", "Part II", "Part III", "Part IV", "Part V"].enumerated() {
            titles[offset * 5] = part
        }

        #expect(ChapterDiff.hasRichTitles(chapters(titles)))
    }

    @Test("an all-generic book is not protected, so the wizard can improve it")
    func allGenericIsReplaceable() {
        #expect(!ChapterDiff.hasRichTitles(chapters((1 ... 22).map { "Chapter \($0)" })))
    }

    @Test("a single chapter is never 'rich' — there is no pattern to judge")
    func singleChapter() {
        #expect(!ChapterDiff.hasRichTitles(chapters(["Melchior"])))
    }

    // MARK: what the user is told

    @Test("the notice names the titles that would be lost, not just that some exist")
    func noticeNamesTitles() throws {
        var titles = (1 ... 24).map { "Chapter \($0)" }
        titles[0] = "Melchior"
        titles[8] = "Ullanor"

        let (skip, message) = ChapterDiff.protectionNotice(
            file: chapters(titles), provider: chapters((1 ... 24).map { "Chapter \($0)" })
        )

        #expect(skip)
        let text = try #require(message)
        #expect(text.contains("Melchior"))
        #expect(text.contains("2"), "it says how many would be lost")
    }
}
