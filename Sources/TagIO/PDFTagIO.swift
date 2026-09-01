import Foundation
import MediaCore
import PDFKit

/// PDF metadata, via PDFKit's document attributes.
///
/// A PDF has no cover atom, so `artwork` carries a rendering of page one for
/// the inspector to show. It is a preview, never written back.
public struct PDFReader: Sendable {
    public init() {}

    public func read(_ url: URL) throws -> MediaItem {
        guard let document = PDFDocument(url: url) else {
            throw TagIOError.unreadable(url, "PDFKit could not open this file")
        }

        var tags = TagSet()
        let attributes = document.documentAttributes ?? [:]
        for (attribute, key) in PDFKeyMap.attributes {
            guard let value = attributes[attribute] else { continue }
            if let text = value as? String, !text.isEmpty {
                tags[key] = .string(text)
            } else if let list = value as? [String], !list.isEmpty {
                tags[key] = .string(list.joined(separator: "/"))
            }
        }
        if let date = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date {
            tags[.year] = .number(Calendar(identifier: .gregorian).component(.year, from: date))
        }

        var item = MediaItem(url: url, kind: .book, container: .pdf, tags: tags)
        item.chapters = Self.outline(of: document)
        if let preview = Self.firstPage(of: document) {
            item.artwork = [Artwork(role: .cover, data: preview, mimeType: "image/png")]
        }
        return item
    }

    /// The PDF outline, as chapters. `start` carries the reading order — a book
    /// has no timeline, and pretending otherwise would print nonsense durations.
    static func outline(of document: PDFDocument) -> [Chapter] {
        guard let root = document.outlineRoot else { return [] }
        var chapters: [Chapter] = []
        func walk(_ node: PDFOutline) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                if let label = child.label, !label.isEmpty {
                    chapters.append(Chapter(
                        index: chapters.count, start: TimeInterval(chapters.count), title: label))
                }
                walk(child)
            }
        }
        walk(root)
        return chapters
    }

    static func firstPage(of document: PDFDocument) -> Data? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(1, 600 / max(bounds.width, bounds.height))
        let image = page.thumbnail(
            of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// The shared table, same rule as every other format: never add to one side.
public enum PDFKeyMap {
    static let attributes: [(PDFDocumentAttribute, TagKey)] = [
        (.titleAttribute, .title),
        (.authorAttribute, .author),
        (.subjectAttribute, .synopsis),
        (.keywordsAttribute, .genre),
        (.creatorAttribute, .publisher),
    ]
}

/// Writes PDF metadata by re-serialising through PDFKit.
///
/// Verified beforehand that a metadata-only rewrite preserves annotations and
/// outlines. What it cannot preserve is a signature — any rewrite invalidates
/// one — and it cannot rewrite an encrypted file at all, so both are refused
/// with a reason rather than silently damaged. Same call the ID3 writer makes
/// on v2.2 tags.
public struct PDFTagWriter: Sendable {
    private let backups: TagBackupStore?

    public init(backups: TagBackupStore? = nil) {
        self.backups = backups
    }

    public func write(_ tags: TagSet, to url: URL) throws {
        guard let document = PDFDocument(url: url) else {
            throw TagIOError.unreadable(url, "PDFKit could not open this file")
        }
        guard !document.isEncrypted, !document.isLocked else {
            throw TagIOError.writeFailed(url, "this PDF is encrypted; OmniTag will not re-encode it")
        }
        if Self.isSigned(document) {
            throw TagIOError.writeFailed(
                url, "this PDF carries a digital signature, which any rewrite would invalidate")
        }

        if let backups {
            try backups.record(try PDFReader().read(url).tags, for: url)
        }

        var attributes = document.documentAttributes ?? [:]
        for (attribute, key) in PDFKeyMap.attributes {
            guard let value = tags[key]?.stringValue, !value.isEmpty else {
                attributes.removeValue(forKey: attribute)
                continue
            }
            attributes[attribute] = attribute == PDFDocumentAttribute.keywordsAttribute
                ? value.split(separator: "/").map(String.init)
                : value
        }
        document.documentAttributes = attributes

        let temporary = url.deletingLastPathComponent()
            .appending(path: ".omnitag-\(UUID().uuidString).pdf")
        guard document.write(to: temporary) else {
            try? FileManager.default.removeItem(at: temporary)
            throw TagIOError.writeFailed(url, "PDFKit refused to write the file")
        }

        // Prove it reopens with the pages intact before replacing anything.
        guard let verification = PDFDocument(url: temporary),
              verification.pageCount == document.pageCount else {
            try? FileManager.default.removeItem(at: temporary)
            throw TagIOError.writeFailed(url, "verification failed: the rewritten PDF lost pages")
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw TagIOError.writeFailed(url, error.localizedDescription)
        }
    }

    /// A signature lives in an AcroForm signature field; PDFKit surfaces those
    /// as widget annotations with a signature field type.
    static func isSigned(_ document: PDFDocument) -> Bool {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where annotation.widgetFieldType == .signature {
                return true
            }
        }
        return false
    }
}
