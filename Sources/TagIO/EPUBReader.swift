import Foundation
import MediaCore

/// Reads an EPUB's package document. Both EPUB 2 and 3 — they differ in where
/// series and cover live, and real libraries contain plenty of both.
public struct EPUBReader: Sendable {
    public init() {}

    public func read(_ url: URL) throws -> MediaItem {
        let archive = try ZipArchive(url: url)
        let opfPath = try Self.packagePath(in: archive, url: url)
        let package = try OPFDocument(try archive.data(at: opfPath))

        var item = MediaItem(
            url: url, kind: .book, container: .epub,
            tags: EPUBKeyMap.tags(from: package),
            chapters: [], artwork: [])

        if let href = package.coverHref,
           let data = try? archive.data(at: Self.resolve(href, relativeTo: opfPath)) {
            item.artwork = [Artwork(role: .cover, data: data, mimeType: Artwork.sniffMimeType(data))]
        }
        item.chapters = (try? TableOfContents.read(archive, package: package, opfPath: opfPath)) ?? []
        return item
    }

    /// `META-INF/container.xml` names the package document. Its location is the
    /// one path in an EPUB that is fixed by the spec.
    static func packagePath(in archive: ZipArchive, url: URL) throws -> String {
        guard let containerData = try? archive.data(at: "META-INF/container.xml") else {
            throw TagIOError.unreadable(url, "not an EPUB: META-INF/container.xml is missing")
        }
        let container = String(decoding: containerData, as: UTF8.self)
        guard let range = container.range(of: #"full-path\s*=\s*["']([^"']+)["']"#, options: .regularExpression),
              let quoted = container[range].range(of: #"["'][^"']+["']"#, options: .regularExpression)
        else {
            throw TagIOError.unreadable(url, "container.xml names no package document")
        }
        let path = String(container[quoted].dropFirst().dropLast())
        guard archive.contains(path) else {
            throw TagIOError.unreadable(url, "the package document \(path) is not in the archive")
        }
        return path
    }

    /// Manifest hrefs are relative to the package document, not to the root.
    static func resolve(_ href: String, relativeTo opfPath: String) -> String {
        let base = opfPath.contains("/")
            ? String(opfPath[..<opfPath.lastIndex(of: "/")!]) + "/"
            : ""
        let joined = base + (href.removingPercentEncoding ?? href)
        // Collapse any "../" the href used to climb out of the package folder.
        var parts: [String] = []
        for component in joined.split(separator: "/", omittingEmptySubsequences: true) {
            if component == ".." { parts.removeLast(parts.isEmpty ? 0 : 1) }
            else if component != "." { parts.append(String(component)) }
        }
        return parts.joined(separator: "/")
    }
}

/// The EPUB table of contents, read as chapters. Read-only: an EPUB's nav
/// document is navigation over content, and rewriting it is editing the book,
/// not tagging it.
enum TableOfContents {
    static func read(_ archive: ZipArchive, package: OPFDocument, opfPath: String) throws -> [Chapter] {
        // EPUB 3 nav document, else the EPUB 2 NCX.
        let navHref = package.manifest.values.first {
            $0.properties?.split(separator: " ").contains("nav") ?? false
        }?.href
        let ncxHref = package.manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }?.href

        if let href = navHref,
           let data = try? archive.data(at: EPUBReader.resolve(href, relativeTo: opfPath)) {
            let titles = matches(of: #"<a[^>]*>([^<]+)</a>"#, in: String(decoding: data, as: UTF8.self))
            if !titles.isEmpty { return chapters(from: titles) }
        }
        if let href = ncxHref,
           let data = try? archive.data(at: EPUBReader.resolve(href, relativeTo: opfPath)) {
            let titles = matches(of: #"<text>([^<]*)</text>"#, in: String(decoding: data, as: UTF8.self))
            // The NCX's first <text> is the book title inside <docTitle>.
            return chapters(from: Array(titles.dropFirst()))
        }
        return []
    }

    /// A book has no timeline, so `start` carries the reading order instead —
    /// the inspector shows the index, and nothing pretends these are seconds.
    private static func chapters(from titles: [String]) -> [Chapter] {
        titles.enumerated().map { offset, title in
            Chapter(index: offset, start: TimeInterval(offset), title: title)
        }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match in
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                let title = text[range]
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? nil : title
            }
    }
}
