import Foundation
@testable import MediaCore
import Testing

@Suite("FilenamePattern")
struct FilenamePatternTests {
    // MARK: - Parsing the pattern itself

    @Test("a pattern splits into literals and fields")
    func tokenises() {
        let pattern = FilenamePattern("%artist% - %title%")
        #expect(pattern.tokens == [
            .field(.artist), .literal(" - "), .field(.title)
        ])
    }

    @Test("an unknown placeholder becomes a custom key rather than literal text")
    func unknownPlaceholder() {
        #expect(FilenamePattern("%mood%").tokens == [.field(.custom("MOOD"))])
    }

    @Test("an unclosed percent is literal text, not a field")
    func unclosedPercent() {
        #expect(FilenamePattern("50% off").tokens == [.literal("50% off")])
    }

    @Test("%% is an escaped percent sign")
    func escapedPercent() {
        #expect(FilenamePattern("100%% %title%").tokens
            == [.literal("100% "), .field(.title)])
    }

    @Test("fields are named the same way the wizard names them")
    func fieldVocabulary() {
        #expect(FilenamePattern("%show%").tokens == [.field(.showName)])
        #expect(FilenamePattern("%season%").tokens == [.field(.seasonNumber)])
        #expect(FilenamePattern("%albumartist%").tokens == [.field(.albumArtist)])
        #expect(FilenamePattern("%TITLE%").tokens == [.field(.title)])
    }

    // MARK: - Tag → filename

    private func music() -> TagSet {
        var tags = TagSet()
        tags.title = "Laura Palmer's Theme"
        tags.artist = "Angelo Badalamenti"
        tags.album = "Twin Peaks"
        tags[.trackNumber] = .number(4)
        return tags
    }

    @Test("rendering substitutes tag values")
    func rendersValues() {
        let rendered = FilenamePattern("%artist% - %title%").render(music())
        #expect(rendered.name == "Angelo Badalamenti - Laura Palmer's Theme")
        #expect(rendered.missing.isEmpty)
    }

    @Test("counting fields are zero-padded to two digits")
    func padsNumbers() {
        #expect(FilenamePattern("%track% %title%").render(music()).name
            == "04 Laura Palmer's Theme")
    }

    @Test("a missing field renders empty and is reported")
    func reportsMissing() {
        let rendered = FilenamePattern("%artist% - %genre%").render(music())
        #expect(rendered.missing == [.genre])
        #expect(rendered.name == "Angelo Badalamenti -")
    }

    @Test("path separators and colons cannot escape the folder")
    func sanitisesSeparators() {
        var tags = TagSet()
        tags.title = "AC/DC: Live"
        #expect(FilenamePattern("%title%").render(tags).name == "AC-DC- Live")
    }

    @Test("leading dots and trailing dots or spaces are trimmed")
    func trimsHostileEdges() {
        var tags = TagSet()
        tags.title = ".hidden."
        #expect(FilenamePattern("%title% ").render(tags).name == "hidden")
    }

    @Test("a name that renders empty is reported rather than returned")
    func emptyRender() {
        #expect(FilenamePattern("%genre%").render(music()).name.isEmpty)
    }

    @Test("runs of whitespace collapse, so a missing field leaves no double space")
    func collapsesWhitespace() {
        var tags = TagSet()
        tags.title = "Theme"
        #expect(FilenamePattern("%artist% %title%").render(tags).name == "Theme")
    }

    @Test("a rendered name is capped to a length every filesystem accepts")
    func capsLength() {
        var tags = TagSet()
        tags.title = String(repeating: "a", count: 400)
        #expect(FilenamePattern("%title%").render(tags).name.utf8.count <= 200)
    }

    // MARK: - Filename → tags

    @Test("a filename is parsed back into the fields the pattern names")
    func parsesFilename() throws {
        let tags = try #require(
            FilenamePattern("%artist% - %title%").parse("Angelo Badalamenti - Laura Palmer's Theme")
        )
        #expect(tags.artist == "Angelo Badalamenti")
        #expect(tags.title == "Laura Palmer's Theme")
    }

    @Test("counting fields parse as numbers, leading zeros dropped")
    func parsesNumbers() throws {
        let tags = try #require(
            FilenamePattern("S%season%E%episode% - %title%").parse("S01E03 - Zen")
        )
        #expect(tags[.seasonNumber] == .number(1))
        #expect(tags[.episodeNumber] == .number(3))
        #expect(tags.title == "Zen")
    }

    @Test("a filename that does not match the pattern parses to nil")
    func rejectsMismatch() {
        #expect(FilenamePattern("%artist% - %title%").parse("Northwest Passage") == nil)
    }

    @Test("regex metacharacters in the literal parts are matched literally")
    func escapesLiterals() throws {
        let tags = try #require(FilenamePattern("(%year%) %title%").parse("(1990) Pilot"))
        #expect(tags.year == 1990)
        #expect(tags.title == "Pilot")
    }

    @Test("parsing takes a filename with or without its extension")
    func stripsExtension() throws {
        let tags = try #require(FilenamePattern("%title%").parse("Pilot.m4a"))
        #expect(tags.title == "Pilot")
    }

    @Test("captured values are trimmed of surrounding whitespace")
    func trimsCaptures() throws {
        let tags = try #require(FilenamePattern("%artist% -%title%").parse("Badalamenti - Theme"))
        #expect(tags.artist == "Badalamenti")
        #expect(tags.title == "Theme")
    }

    @Test("a field that captures nothing is left unset rather than set empty")
    func skipsEmptyCaptures() throws {
        let tags = try #require(FilenamePattern("%artist%-%title%").parse("-Theme"))
        #expect(tags.artist == nil)
        #expect(tags.title == "Theme")
    }

    @Test("a pattern with no fields never parses anything")
    func literalOnlyPattern() {
        #expect(FilenamePattern("Twin Peaks").parse("Twin Peaks") == nil)
    }

    @Test("the same field twice must agree in the filename")
    func repeatedField() {
        let pattern = FilenamePattern("%artist% - %artist%")
        #expect(pattern.parse("A - B") == nil)
        #expect(pattern.parse("A - A")?.artist == "A")
    }
}
