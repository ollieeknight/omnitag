import Foundation
import MediaCore
@testable import OmniTagApp
import Testing

@MainActor
@Suite("Custom tags")
struct CustomTagTests {
    private func model(_ tags: TagSet) -> LibraryModel {
        let url = URL(filePath: "/tmp/\(UUID().uuidString).m4b")
        let model = LibraryModel()
        model.items = [MediaItem(url: url, kind: .audiobook, container: .m4b, tags: tags)]
        model.selection = [url]
        return model
    }

    @Test("a file's unmanaged tags are listed, in a stable order")
    func customTagsAreListed() {
        var tags = TagSet()
        tags[.title] = .string("Horus Rising")
        tags[.custom("RATING")] = .string("4.8")
        tags[.custom("FORMAT")] = .string("unabridged")

        let listed = model(tags).customTags

        #expect(listed.map(\.name) == ["FORMAT", "RATING"], "alphabetical, so the list does not jump about")
        #expect(listed.first?.value == "unabridged")
    }

    @Test("managed fields are never listed as custom")
    func managedFieldsExcluded() {
        var tags = TagSet()
        tags[.title] = .string("Horus Rising")
        tags[.author] = .string("Dan Abnett")

        #expect(model(tags).customTags.isEmpty)
    }

    /// The developer's Audible files carry a multi-kilobyte base64 blob. It
    /// must round-trip, but showing it raw would fill the inspector.
    @Test("a very long value is truncated for display but kept whole underneath")
    func longValuesAreTruncated() throws {
        var tags = TagSet()
        tags[.custom("JSON")] = .string(String(repeating: "x", count: 5000))

        let entry = try #require(model(tags).customTags.first)

        #expect(entry.value.count == 5000, "the value itself is untouched")
        #expect(entry.displayValue.count < 200, "what is shown is not")
        #expect(entry.isTruncated)
    }

    @Test("a short value is shown in full and not marked truncated")
    func shortValuesAreWhole() throws {
        var tags = TagSet()
        tags[.custom("RATING")] = .string("4.8")

        let entry = try #require(model(tags).customTags.first)

        #expect(entry.displayValue == "4.8")
        #expect(!entry.isTruncated)
    }

    @Test("only the fields every selected file shares are listed")
    func multiSelectionShowsCommonOnly() {
        var first = TagSet()
        first[.custom("RATING")] = .string("4.8")
        first[.custom("FORMAT")] = .string("unabridged")
        var second = TagSet()
        second[.custom("RATING")] = .string("4.8")

        let model = LibraryModel()
        let a = URL(filePath: "/tmp/a.m4b"), b = URL(filePath: "/tmp/b.m4b")
        model.items = [
            MediaItem(url: a, kind: .audiobook, container: .m4b, tags: first),
            MediaItem(url: b, kind: .audiobook, container: .m4b, tags: second)
        ]
        model.selection = [a, b]

        #expect(model.customTags.map(\.name) == ["RATING"])
    }
}
