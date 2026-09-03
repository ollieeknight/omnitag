import Foundation
import MediaCore
@testable import TagIO
import Testing

/// Builds EPUBs through our own writer, the way `EBMLBuilder` builds Matroska:
/// generated in the test, never committed.
enum EPUBBuilder {
    static let opfPath = "ops/content.opf"

    /// An EPUB 2 package shaped like the developer's real one — including the
    /// `<description>` in a default Dublin Core namespace and the EPUB 2 cover
    /// convention, both of which a naive parser gets wrong.
    static func package(
        title: String = "The Secret Diary of Laura Palmer",
        creator: String = "Jennifer Lynch",
        extraMetadata: String = "",
        includeDescription: Bool = true
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
        <dc:title>\(title)</dc:title>
        <dc:creator opf:role="aut">\(creator)</dc:creator>
        <dc:identifier id="bookid">9781451664782</dc:identifier>
        <dc:language>En</dc:language>
        <dc:publisher>Gallery Books</dc:publisher>
        <dc:date>1990-09-15</dc:date>
        <dc:subject>Mystery</dc:subject>
        <dc:subject>Horror</dc:subject>
        <meta content="my-cover-image" name="cover"/>
        <meta name="private-thing" content="must survive"/>
        \(includeDescription ? #"<description xmlns="http://purl.org/dc/elements/1.1/">Laura Palmer&apos;s diary.</description>"# : "")
        \(extraMetadata)
        </metadata>
        <manifest>
        <item href="toc.ncx" id="ncx" media-type="application/x-dtbncx+xml"/>
        <item href="images/cover.jpg" id="my-cover-image" media-type="image/jpeg"/>
        <item href="xhtml/ch01.html" id="ch01" media-type="application/xhtml+xml"/>
        </manifest>
        <spine toc="ncx"><itemref idref="ch01"/></spine>
        </package>
        """
    }

    static let ncx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
    <docTitle><text>The Secret Diary of Laura Palmer</text></docTitle>
    <navMap>
    <navPoint id="n1"><navLabel><text>July 22, 1984</text></navLabel><content src="xhtml/ch01.html"/></navPoint>
    <navPoint id="n2"><navLabel><text>July 23, 1984</text></navLabel><content src="xhtml/ch02.html"/></navPoint>
    </navMap>
    </ncx>
    """

    /// A tiny but genuine JPEG, so cover reading exercises real bytes.
    static let coverJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x20, count: 64) + [0xFF, 0xD9])

    static func write(package opf: String = package(), to url: URL) throws {
        try ZipArchive.write([
            .init(path: "mimetype", data: Data("application/epub+zip".utf8)),
            .init(path: "META-INF/container.xml", data: Data("""
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8)),
            .init(path: opfPath, data: Data(opf.utf8)),
            .init(path: "ops/toc.ncx", data: Data(ncx.utf8)),
            .init(path: "ops/images/cover.jpg", data: coverJPEG),
            .init(path: "ops/xhtml/ch01.html", data: Data("<html><body>Dear Diary</body></html>".utf8))
        ], to: url)
    }

    static func temporaryDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "omnitag-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("EPUB reading")
struct EPUBReadingTests {
    private func book(_ opf: String = EPUBBuilder.package()) throws -> (MediaItem, URL) {
        let directory = try EPUBBuilder.temporaryDirectory()
        let url = directory.appending(path: "diary.epub")
        try EPUBBuilder.write(package: opf, to: url)
        return try (EPUBReader().read(url), directory)
    }

    @Test("reads the Dublin Core fields a tagger cares about")
    func readsDublinCore() throws {
        let (item, directory) = try book()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(item.kind == .book)
        #expect(item.container == .epub)
        #expect(item.tags.title == "The Secret Diary of Laura Palmer")
        #expect(item.tags[.author]?.stringValue == "Jennifer Lynch")
        #expect(item.tags[.publisher]?.stringValue == "Gallery Books")
        #expect(item.tags[.language]?.stringValue == "En")
        #expect(item.tags[.year]?.intValue == 1990)
    }

    @Test("a description in a default namespace is not lost to prefix matching")
    func readsDefaultNamespacedDescription() throws {
        // The real Laura Palmer EPUB writes <description> with a default
        // Dublin Core namespace rather than a dc: prefix.
        let (item, directory) = try book()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(item.tags[.synopsis]?.stringValue == "Laura Palmer's diary.")
    }

    @Test("several dc:subject elements become one genre field")
    func joinsSubjects() throws {
        let (item, directory) = try book()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(item.tags.genre == "Mystery/Horror")
    }

    @Test("a bare dc:identifier that looks like an ISBN is read as one")
    func readsISBN() throws {
        let (item, directory) = try book()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(item.tags[.isbn]?.stringValue == "9781451664782")
    }

    @Test("the EPUB 2 cover convention finds the cover image")
    func readsLegacyCover() throws {
        let (item, directory) = try book()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(item.artwork.first?.data == EPUBBuilder.coverJPEG)
        #expect(item.artwork.first?.mimeType == "image/jpeg")
    }

    @Test("the EPUB 3 cover-image property is honoured too")
    func readsModernCover() throws {
        let opf = EPUBBuilder.package()
            .replacingOccurrences(of: #"<meta content="my-cover-image" name="cover"/>"#, with: "")
            .replacingOccurrences(
                of: #"<item href="images/cover.jpg" id="my-cover-image" media-type="image/jpeg"/>"#,
                with: #"<item href="images/cover.jpg" id="c" media-type="image/jpeg" properties="cover-image"/>"#
            )
        let (item, directory) = try book(opf)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(item.artwork.first?.data == EPUBBuilder.coverJPEG)
    }

    @Test("calibre series metadata is read, because real libraries carry it")
    func readsCalibreSeries() throws {
        let opf = EPUBBuilder.package(extraMetadata: """
        <meta name="calibre:series" content="Twin Peaks"/>
        <meta name="calibre:series_index" content="1.0"/>
        """)
        let (item, directory) = try book(opf)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(item.tags[.series]?.stringValue == "Twin Peaks")
        #expect(item.tags[.seriesIndex]?.intValue == 1)
    }

    @Test("the NCX becomes the table of contents, without the book title")
    func readsTableOfContents() throws {
        let (item, directory) = try book()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(item.chapters.map(\.title) == ["July 22, 1984", "July 23, 1984"])
    }

    @Test("a zip that is not an EPUB is refused with a reason")
    func refusesNonEPUB() throws {
        let directory = try EPUBBuilder.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "plain.epub")
        try ZipArchive.write([.init(path: "hello.txt", data: Data("hi".utf8))], to: url)

        #expect(throws: (any Error).self) { try EPUBReader().read(url) }
    }
}

@Suite("EPUB writing")
struct EPUBWritingTests {
    private func staged(_ opf: String = EPUBBuilder.package()) throws -> (URL, URL) {
        let directory = try EPUBBuilder.temporaryDirectory()
        let url = directory.appending(path: "diary.epub")
        try EPUBBuilder.write(package: opf, to: url)
        return (url, directory)
    }

    @Test("edited fields are written and read back")
    func writesFields() throws {
        let (url, directory) = try staged()
        defer { try? FileManager.default.removeItem(at: directory) }

        var tags = try EPUBReader().read(url).tags
        tags.title = "The Secret Diary"
        tags[.author] = .string("J. Lynch")
        tags[.series] = .string("Twin Peaks")
        tags[.seriesIndex] = .number(1)
        try EPUBTagWriter().write(tags, to: url)

        let reread = try EPUBReader().read(url).tags
        #expect(reread.title == "The Secret Diary")
        #expect(reread[.author]?.stringValue == "J. Lynch")
        #expect(reread[.series]?.stringValue == "Twin Peaks")
        #expect(reread[.seriesIndex]?.intValue == 1)
    }

    @Test("the rewritten archive still opens with the system unzip")
    func staysAValidArchive() throws {
        let (url, directory) = try staged()
        defer { try? FileManager.default.removeItem(at: directory) }

        var tags = try EPUBReader().read(url).tags
        tags.title = "Renamed"
        try EPUBTagWriter().write(tags, to: url)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-t", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(output)")
    }

    @Test("metadata we do not manage survives the write")
    func preservesUnmanagedMetadata() throws {
        let (url, directory) = try staged()
        defer { try? FileManager.default.removeItem(at: directory) }

        var tags = try EPUBReader().read(url).tags
        tags.title = "Renamed"
        try EPUBTagWriter().write(tags, to: url)

        let archive = try ZipArchive(url: url)
        let opf = try String(decoding: archive.data(at: EPUBBuilder.opfPath), as: UTF8.self)
        #expect(opf.contains("private-thing"), "an unmanaged <meta> was dropped")
        #expect(opf.contains("must survive"))
        #expect(opf.contains("my-cover-image"), "the cover pointer was dropped")
    }

    @Test("everything outside the metadata block is left alone")
    func preservesTheRestOfThePackage() throws {
        let (url, directory) = try staged()
        defer { try? FileManager.default.removeItem(at: directory) }

        var tags = try EPUBReader().read(url).tags
        tags.title = "Renamed"
        try EPUBTagWriter().write(tags, to: url)

        let archive = try ZipArchive(url: url)
        let opf = try String(decoding: archive.data(at: EPUBBuilder.opfPath), as: UTF8.self)
        #expect(opf.contains("<spine toc=\"ncx\">"))
        #expect(opf.contains("<item href=\"toc.ncx\" id=\"ncx\""))
        #expect(opf.contains("unique-identifier=\"bookid\""))
    }

    @Test("the other entries come out byte-identical")
    func preservesOtherEntries() throws {
        let (url, directory) = try staged()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try ZipArchive(url: url)
        let chapterBefore = try before.data(at: "ops/xhtml/ch01.html")
        let coverBefore = try before.data(at: "ops/images/cover.jpg")

        var tags = try EPUBReader().read(url).tags
        tags.title = "Renamed"
        try EPUBTagWriter().write(tags, to: url)

        let after = try ZipArchive(url: url)
        #expect(try after.data(at: "ops/xhtml/ch01.html") == chapterBefore)
        #expect(try after.data(at: "ops/images/cover.jpg") == coverBefore)
        #expect(after.paths == before.paths)
    }

    @Test("mimetype stays first and stored after a rewrite")
    func mimetypeSurvives() throws {
        let (url, directory) = try staged()
        defer { try? FileManager.default.removeItem(at: directory) }

        var tags = try EPUBReader().read(url).tags
        tags.title = "Renamed"
        try EPUBTagWriter().write(tags, to: url)

        let archive = try ZipArchive(url: url)
        #expect(archive.entries.first?.path == "mimetype")
        #expect(archive.entries.first?.isStored == true)
    }

    @Test("an existing cover can be replaced")
    func replacesCover() throws {
        let (url, directory) = try staged()
        defer { try? FileManager.default.removeItem(at: directory) }

        let newCover = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 0x11, count: 40))
        let tags = try EPUBReader().read(url).tags
        try EPUBTagWriter().write(tags, artwork: [Artwork(data: newCover, mimeType: "image/png")], to: url)

        #expect(try EPUBReader().read(url).artwork.first?.data == newCover)
    }

    @Test("a failed write leaves the original untouched")
    func failedWriteLeavesOriginalAlone() throws {
        let directory = try EPUBBuilder.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "broken.epub")
        // An archive with no <metadata> element: the writer must refuse it.
        try ZipArchive.write([
            .init(path: "mimetype", data: Data("application/epub+zip".utf8)),
            .init(path: "META-INF/container.xml", data: Data("""
            <container><rootfiles><rootfile full-path="c.opf"/></rootfiles></container>
            """.utf8)),
            .init(path: "c.opf", data: Data("<package><manifest/></package>".utf8))
        ], to: url)
        let before = try Data(contentsOf: url)

        #expect(throws: (any Error).self) {
            var tags = TagSet()
            tags.title = "Nope"
            try EPUBTagWriter().write(tags, to: url)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1,
                "a temp file was left behind")
    }
}

@Suite("EPUB against the real book", .enabled(if: TwinPeaks.realMediaRoot != nil))
struct RealEPUBTests {
    /// The developer's own copy. Copied to a temp directory before anything
    /// touches it — a test never writes to real media.
    private func copyOfRealBook() throws -> (URL, URL) {
        let root = try #require(TwinPeaks.realMediaRoot)
        let original = root.appending(path: "The Secret Diary of Laura Palmer - Jennifer Lynch.epub")
        try #require(FileManager.default.fileExists(atPath: original.path),
                     "the real EPUB is not in \(root.path)")

        let directory = try EPUBBuilder.temporaryDirectory()
        let copy = directory.appending(path: original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: copy)
        return (copy, directory)
    }

    @Test("reads the real Laura Palmer EPUB")
    func readsTheRealBook() throws {
        let (url, directory) = try copyOfRealBook()
        defer { try? FileManager.default.removeItem(at: directory) }

        let item = try EPUBReader().read(url)
        #expect(item.tags.title == "The Secret Diary of Laura Palmer")
        #expect(item.tags[.author]?.stringValue == "Jennifer Lynch")
        #expect(item.tags[.publisher]?.stringValue == "Gallery Books")
        #expect(item.tags[.isbn]?.stringValue == "9781451664782")
        // The summary lives in a default-namespaced <description>; a prefix
        // matcher reads nothing here.
        #expect(item.tags[.synopsis]?.stringValue?.contains("Laura Palmer") == true)
        #expect(!item.artwork.isEmpty, "the EPUB 2 cover pointer was not followed")
        #expect(!item.chapters.isEmpty, "the table of contents was not read")
    }

    @Test("writes the real book without breaking it")
    func writesTheRealBook() throws {
        let (url, directory) = try copyOfRealBook()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try ZipArchive(url: url)
        let entryCount = before.paths.count
        let sampleEntry = try #require(before.paths.first { $0.hasSuffix(".html") })
        let sampleBefore = try before.data(at: sampleEntry)

        var tags = try EPUBReader().read(url).tags
        tags[.series] = .string("Twin Peaks")
        tags[.seriesIndex] = .number(1)
        try EPUBTagWriter().write(tags, to: url)

        let reread = try EPUBReader().read(url)
        #expect(reread.tags[.series]?.stringValue == "Twin Peaks")
        #expect(reread.tags.title == "The Secret Diary of Laura Palmer")
        #expect(!reread.artwork.isEmpty, "the cover was lost")

        let after = try ZipArchive(url: url)
        #expect(after.paths.count == entryCount, "entries were lost")
        #expect(try after.data(at: sampleEntry) == sampleBefore, "chapter content was altered")

        // The strongest check available: a real EPUB reader must still open it.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-t", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(output)")
    }
}
