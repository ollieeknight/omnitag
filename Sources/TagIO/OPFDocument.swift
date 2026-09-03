import Foundation
import MediaCore

/// The OPF package document — an EPUB's metadata lives in its `<metadata>`
/// block as Dublin Core elements.
///
/// Two things this deliberately does *not* do. It does not match on the `dc:`
/// prefix, because a prefix is a local nickname for a namespace and real files
/// use others: the developer's copy of *The Secret Diary of Laura Palmer*
/// declares `<description>` in a default Dublin Core namespace, and a prefix
/// matcher loses the summary silently. And it does not regenerate the XML on
/// write — see `replacingMetadata`.
struct OPFDocument {
    static let dublinCore = "http://purl.org/dc/elements/1.1/"
    static let opf = "http://www.idpf.org/2007/opf"

    struct Element {
        var name: String // local name, namespace stripped
        var namespace: String?
        var attributes: [String: String]
        var text: String
    }

    /// Dublin Core and `<meta>` elements, in document order.
    let metadata: [Element]
    /// Manifest items by id: `(href, mediaType, properties)`.
    let manifest: [String: (href: String, mediaType: String, properties: String?)]
    /// The raw source, kept so writes can be surgical.
    let source: String

    init(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw TagIOError.unreadable(URL(filePath: "content.opf"), "the OPF is not text")
        }
        source = text

        let parser = OPFParser()
        try parser.parse(data)
        metadata = parser.metadata
        manifest = parser.manifest
    }

    /// The first metadata element with this local name in the Dublin Core
    /// namespace, whatever prefix the file happens to use for it.
    func dc(_ name: String) -> Element? {
        metadata.first { $0.name == name && $0.namespace == Self.dublinCore }
    }

    func allDC(_ name: String) -> [Element] {
        metadata.filter { $0.name == name && $0.namespace == Self.dublinCore }
    }

    /// `<meta name="…" content="…">` — the EPUB 2 form.
    func legacyMeta(name: String) -> String? {
        metadata.first { $0.name == "meta" && $0.attributes["name"] == name }?
            .attributes["content"]
    }

    /// `<meta property="…">value</meta>` — the EPUB 3 form.
    func meta(property: String) -> String? {
        metadata.first { $0.name == "meta" && $0.attributes["property"] == property }?.text
    }

    /// The manifest href of the cover image, by either convention.
    var coverHref: String? {
        if let epub3 = manifest.values.first(where: {
            $0.properties?.split(separator: " ").contains("cover-image") ?? false
        }) {
            return epub3.href
        }
        if let id = legacyMeta(name: "cover"), let item = manifest[id] {
            return item.href
        }
        // Last resort: a manifest image whose id or href says "cover".
        return manifest.first { key, value in
            value.mediaType.hasPrefix("image/")
                && (key.localizedCaseInsensitiveContains("cover")
                    || value.href.localizedCaseInsensitiveContains("cover"))
        }?.value.href
    }

    /// Replace the contents of `<metadata>` and leave every other byte alone.
    ///
    /// Regenerating the package document would drop the manifest, spine, guide
    /// and every namespace declaration the file carries — which is the whole
    /// book. The lossless round-trip invariant makes surgery the only option.
    func replacingMetadata(with inner: String) throws -> Data {
        guard let open = Self.range(ofElement: "metadata", in: source) else {
            throw TagIOError.writeFailed(
                URL(filePath: "content.opf"), "the OPF has no <metadata> element"
            )
        }
        var rebuilt = source
        rebuilt.replaceSubrange(open.inner, with: inner)
        guard let data = rebuilt.data(using: .utf8) else {
            throw TagIOError.writeFailed(URL(filePath: "content.opf"), "the rewritten OPF is not encodable")
        }
        return data
    }

    /// The ranges of a named element's open tag, inner content, and whole span.
    /// Deliberately blunt: an OPF is machine-written and its `<metadata>` block
    /// does not nest another element of the same name.
    static func range(ofElement name: String, in text: String)
        -> (whole: Range<String.Index>, inner: Range<String.Index>)? {
        guard let openStart = text.range(of: "<\(name)", options: [.caseInsensitive]),
              let openEnd = text.range(of: ">", range: openStart.upperBound ..< text.endIndex),
              let close = text.range(of: "</\(name)", options: [.caseInsensitive, .backwards]),
              let closeEnd = text.range(of: ">", range: close.upperBound ..< text.endIndex)
        else { return nil }
        return (openStart.lowerBound ..< closeEnd.upperBound, openEnd.upperBound ..< close.lowerBound)
    }

    /// XML text escaping — the five predefined entities, nothing clever.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Namespace-aware `XMLParser` delegate. `shouldProcessNamespaces` means the
/// element name arrives already stripped of its prefix and the namespace URI
/// arrives separately, which is exactly the distinction that matters here.
private final class OPFParser: NSObject, XMLParserDelegate {
    var metadata: [OPFDocument.Element] = []
    var manifest: [String: (href: String, mediaType: String, properties: String?)] = [:]

    private var depth: [String] = []
    private var current: OPFDocument.Element?

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw TagIOError.unreadable(
                URL(filePath: "content.opf"),
                parser.parserError?.localizedDescription ?? "the OPF is not valid XML"
            )
        }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
    ) {
        depth.append(elementName)

        if depth.contains("metadata"), elementName != "metadata" {
            current = OPFDocument.Element(
                name: elementName, namespace: namespaceURI, attributes: attributes, text: ""
            )
        }
        if depth.contains("manifest"), elementName == "item",
           let id = attributes["id"], let href = attributes["href"] {
            manifest[id] = (href, attributes["media-type"] ?? "", attributes["properties"])
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current?.text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        if let element = current, element.name == elementName {
            var finished = element
            finished.text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            metadata.append(finished)
            current = nil
        }
        if depth.last == elementName {
            depth.removeLast()
        }
    }
}
