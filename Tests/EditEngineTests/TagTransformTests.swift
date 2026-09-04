@testable import EditEngine
import Foundation
import MediaCore
import Testing

@Suite("Text transforms")
struct TagTransformTests {
    private func tags(_ title: String) -> TagSet {
        var tags = TagSet()
        tags[.title] = .string(title)
        return tags
    }

    private func apply(_ edit: TagEdit, to title: String) -> String? {
        edit.applied(to: tags(title))[.title]?.stringValue
    }

    // MARK: case

    @Test("title case capitalises words but leaves small words alone inside a title")
    func titleCase() {
        #expect(apply(.transform(.title, .titleCase), to: "the horus heresy") == "The Horus Heresy")
        #expect(apply(.transform(.title, .titleCase), to: "FLIGHT OF THE EISENSTEIN") == "Flight of the Eisenstein")
        // The first word is always capitalised, even when it is a small word.
        #expect(apply(.transform(.title, .titleCase), to: "a thousand sons") == "A Thousand Sons")
    }

    @Test("upper and lower are exactly that")
    func upperAndLower() {
        #expect(apply(.transform(.title, .upperCase), to: "Legion") == "LEGION")
        #expect(apply(.transform(.title, .lowerCase), to: "Legion") == "legion")
    }

    @Test("sentence case capitalises the first letter only")
    func sentenceCase() {
        #expect(apply(.transform(.title, .sentenceCase), to: "KNOW NO FEAR") == "Know no fear")
    }

    // MARK: whitespace

    @Test("trimming collapses runs and strips both ends")
    func trimWhitespace() {
        #expect(apply(.transform(.title, .trimWhitespace), to: "  Betrayer   ") == "Betrayer")
        #expect(apply(.transform(.title, .trimWhitespace), to: "Mark   of  Calth") == "Mark of Calth")
    }

    // MARK: guards

    @Test("a transform on a field the file has not got does nothing")
    func absentFieldUnchanged() {
        let empty = TagSet()
        #expect(TagEdit.transform(.title, .upperCase).applied(to: empty) == empty)
    }

    @Test("a transform that changes nothing leaves the value identical")
    func idempotent() {
        #expect(apply(.transform(.title, .titleCase), to: "The Horus Heresy") == "The Horus Heresy")
        #expect(apply(.transform(.title, .trimWhitespace), to: "Betrayer") == "Betrayer")
    }

    /// A number tag is not text; upper-casing it would turn `.number(3)` into
    /// `.string("3")` and lose the type the writers key on.
    @Test("a numeric value is left alone rather than stringified")
    func numericUntouched() {
        var numeric = TagSet()
        numeric[.trackNumber] = .number(3)
        #expect(TagEdit.transform(.trackNumber, .upperCase).applied(to: numeric) == numeric)
    }

    // MARK: copy and swap

    @Test("copying a field overwrites the destination and leaves the source")
    func copyField() {
        var tags = TagSet()
        tags[.title] = .string("Horus Rising")
        tags[.album] = .string("Old")

        let result = TagEdit.copyField(from: .title, to: .album).applied(to: tags)

        #expect(result[.album]?.stringValue == "Horus Rising")
        #expect(result[.title]?.stringValue == "Horus Rising")
    }

    @Test("copying from an empty field clears the destination rather than writing nothing")
    func copyFromEmpty() {
        var tags = TagSet()
        tags[.album] = .string("Old")

        let result = TagEdit.copyField(from: .title, to: .album).applied(to: tags)

        #expect(result[.album] == nil, "the source is empty, so the destination becomes empty too")
    }

    @Test("swapping exchanges two fields in one step")
    func swapFields() {
        var tags = TagSet()
        tags[.artist] = .string("Dan Abnett")
        tags[.title] = .string("Horus Rising")

        let result = TagEdit.swapFields(.artist, .title).applied(to: tags)

        #expect(result[.artist]?.stringValue == "Horus Rising")
        #expect(result[.title]?.stringValue == "Dan Abnett")
    }

    @Test("swapping when one side is empty moves the value rather than duplicating it")
    func swapWithEmpty() {
        var tags = TagSet()
        tags[.title] = .string("Legion")

        let result = TagEdit.swapFields(.artist, .title).applied(to: tags)

        #expect(result[.artist]?.stringValue == "Legion")
        #expect(result[.title] == nil)
    }
}
