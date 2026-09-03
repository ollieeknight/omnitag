import Foundation
import MediaCore
import PDFKit
@testable import TagIO
import Testing

@Suite("PDF")
struct PDFTests {
    private func temporaryDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "omnitag-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A PDF carrying the things a metadata-only edit must not destroy.
    private func book(in directory: URL, annotated: Bool = true) throws -> URL {
        let document = PDFDocument()
        for index in 0 ..< 3 {
            let page = PDFPage()
            if annotated, index == 0 {
                let note = PDFAnnotation(
                    bounds: CGRect(x: 10, y: 10, width: 80, height: 30),
                    forType: .text, withProperties: nil
                )
                note.contents = "a reader's note"
                page.addAnnotation(note)
            }
            document.insert(page, at: index)
        }
        let outline = PDFOutline()
        let entry = PDFOutline()
        entry.label = "July 22, 1984"
        outline.insertChild(entry, at: 0)
        document.outlineRoot = outline

        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "The Secret Diary of Laura Palmer",
            PDFDocumentAttribute.authorAttribute: "Jennifer Lynch",
            PDFDocumentAttribute.creatorAttribute: "Gallery Books",
            PDFDocumentAttribute.keywordsAttribute: ["Mystery", "Horror"]
        ]
        let url = directory.appending(path: "diary.pdf")
        #expect(document.write(to: url))
        return url
    }

    @Test("reads the document attributes a tagger cares about")
    func readsAttributes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try PDFReader().read(book(in: directory))

        #expect(item.kind == .book)
        #expect(item.container == .pdf)
        #expect(item.tags.title == "The Secret Diary of Laura Palmer")
        #expect(item.tags[.author]?.stringValue == "Jennifer Lynch")
        #expect(item.tags[.publisher]?.stringValue == "Gallery Books")
        #expect(item.tags.genre == "Mystery/Horror")
    }

    @Test("the outline is read as the table of contents")
    func readsOutline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try PDFReader().read(book(in: directory))
        #expect(item.chapters.map(\.title) == ["July 22, 1984"])
    }

    @Test("page one is offered as a preview, not as writable artwork")
    func rendersPreview() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try PDFReader().read(book(in: directory))
        #expect(item.artwork.first?.mimeType == "image/png")
        #expect(item.artwork.first.map { !$0.data.isEmpty } == true)
    }

    @Test("edits round-trip through a write")
    func writesAttributes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try book(in: directory)

        var tags = try PDFReader().read(url).tags
        tags.title = "The Secret Diary"
        tags[.author] = .string("J. Lynch")
        try PDFTagWriter().write(tags, to: url)

        let reread = try PDFReader().read(url).tags
        #expect(reread.title == "The Secret Diary")
        #expect(reread[.author]?.stringValue == "J. Lynch")
    }

    @Test("a metadata write keeps pages, annotations and the outline")
    func preservesContent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try book(in: directory)

        var tags = try PDFReader().read(url).tags
        tags.title = "Renamed"
        try PDFTagWriter().write(tags, to: url)

        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 3)
        #expect(document.page(at: 0)?.annotations.isEmpty == false, "annotations were lost")
        #expect(document.outlineRoot?.numberOfChildren == 1, "the outline was lost")
    }

    @Test("clearing a field removes the attribute rather than writing it blank")
    func clearingRemovesAttribute() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try book(in: directory)

        var tags = try PDFReader().read(url).tags
        tags[.publisher] = nil
        try PDFTagWriter().write(tags, to: url)

        let document = try #require(PDFDocument(url: url))
        let creator = document.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String
        #expect(creator == nil || creator?.isEmpty == true)
    }

    @Test("a file PDFKit cannot open is refused, and the original is untouched")
    func refusesNonPDFs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "not.pdf")
        let junk = Data(repeating: 0x41, count: 300)
        try junk.write(to: url)

        #expect(throws: (any Error).self) { try PDFReader().read(url) }
        #expect(throws: (any Error).self) {
            var tags = TagSet()
            tags.title = "Nope"
            try PDFTagWriter().write(tags, to: url)
        }
        #expect(try Data(contentsOf: url) == junk)
    }

    @Test("an encrypted PDF is refused rather than re-encoded")
    func refusesEncrypted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try book(in: directory)

        let locked = directory.appending(path: "locked.pdf")
        let document = try #require(PDFDocument(url: source))
        #expect(document.write(to: locked, withOptions: [
            .ownerPasswordOption: "owner", .userPasswordOption: "reader"
        ]))

        #expect(throws: (any Error).self) {
            var tags = TagSet()
            tags.title = "Nope"
            try PDFTagWriter().write(tags, to: locked)
        }
    }
}
