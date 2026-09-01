import Foundation
import MediaCore

/// The one table both the EPUB reader and writer consult, per the rule that a
/// key added to one side only is how "my edit vanished on save" happens.
public enum EPUBKeyMap {
    /// Dublin Core element name ↔ tag key, for the plain one-to-one fields.
    static let dublinCore: [(element: String, key: TagKey)] = [
        ("title", .title),
        ("creator", .author),
        ("publisher", .publisher),
        ("description", .synopsis),
        ("language", .language),
        ("subject", .genre),
    ]

    static func key(forElement name: String) -> TagKey? {
        dublinCore.first { $0.element == name }?.key
    }

    static func element(for key: TagKey) -> String? {
        dublinCore.first { $0.key == key }?.element
    }

    /// Everything the writer manages. Anything else in the metadata block is
    /// left exactly where it is.
    static var managedKeys: Set<TagKey> {
        Set(dublinCore.map(\.key)).union([.year, .isbn, .series, .seriesIndex, .subtitle])
    }

    // MARK: - Reading

    static func tags(from package: OPFDocument) -> TagSet {
        var tags = TagSet()

        for (element, key) in dublinCore {
            let values = package.allDC(element).map(\.text).filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            // Several dc:subject elements are normal; join them the way the
            // rest of the app expresses a multi-value genre.
            tags[key] = .string(key == .genre ? values.joined(separator: "/") : values[0])
        }

        if let year = package.dc("date").flatMap({ Self.year(from: $0.text) }) {
            tags[.year] = .number(year)
        }
        if let isbn = Self.isbn(in: package) {
            tags[.isbn] = .string(isbn)
        }
        if let series = package.meta(property: "belongs-to-collection")
            ?? package.legacyMeta(name: "calibre:series") {
            tags[.series] = .string(series)
        }
        if let index = package.meta(property: "group-position")
            ?? package.legacyMeta(name: "calibre:series_index"),
           let number = Int(index.split(separator: ".").first.map(String.init) ?? index) {
            tags[.seriesIndex] = .number(number)
        }
        if let subtitle = package.metadata.first(where: {
            $0.name == "title" && $0.namespace == OPFDocument.dublinCore
        }).flatMap({ _ in package.allDC("title").dropFirst().first?.text }), !subtitle.isEmpty {
            tags[.subtitle] = .string(subtitle)
        }
        return tags
    }

    /// `dc:date` is an ISO-ish string; only the year is meaningful to a tagger.
    static func year(from text: String) -> Int? {
        guard let match = text.range(of: #"\d{4}"#, options: .regularExpression) else { return nil }
        return Int(text[match])
    }

    /// The ISBN, from whichever identifier carries one. Real files put it in a
    /// bare `dc:identifier`, in a `urn:isbn:` URI, or in an `opf:scheme` attribute.
    static func isbn(in package: OPFDocument) -> String? {
        for identifier in package.allDC("identifier") {
            let text = identifier.text.trimmingCharacters(in: .whitespaces)
            let scheme = identifier.attributes["scheme"]?.lowercased()
            let digits = text.replacingOccurrences(of: #"[^0-9Xx]"#, with: "", options: .regularExpression)
            if scheme == "isbn" || text.lowercased().hasPrefix("urn:isbn:") {
                return digits.isEmpty ? text : digits
            }
            if digits.count == 13 || digits.count == 10 { return digits }
        }
        return nil
    }

    // MARK: - Writing

    /// The new inner XML for `<metadata>`: every element we do not manage kept
    /// verbatim in its original order, ours rewritten from the tag set.
    ///
    /// `<meta>` elements that refine something (EPUB 3 `refines=`) are kept too;
    /// dropping one would break the refinement it points at.
    static func metadataXML(for tags: TagSet, from package: OPFDocument) -> String {
        var lines: [String] = []

        for element in package.metadata {
            let isDublinCore = element.namespace == OPFDocument.dublinCore
            if isDublinCore, let key = key(forElement: element.name), managedKeys.contains(key) {
                continue  // rewritten below
            }
            if isDublinCore, element.name == "date" || element.name == "identifier" {
                continue
            }
            if element.name == "meta", let name = element.attributes["name"],
               name == "calibre:series" || name == "calibre:series_index" {
                continue
            }
            if element.name == "meta", let property = element.attributes["property"],
               property == "belongs-to-collection" || property == "group-position" {
                continue
            }
            lines.append(serialise(element))
        }

        for (element, key) in dublinCore {
            guard let value = tags[key]?.stringValue, !value.isEmpty else { continue }
            if key == .genre {
                for subject in value.split(separator: "/") {
                    lines.append("<dc:\(element)>\(OPFDocument.escape(String(subject)))</dc:\(element)>")
                }
            } else {
                lines.append("<dc:\(element)>\(OPFDocument.escape(value))</dc:\(element)>")
            }
        }
        if let subtitle = tags[.subtitle]?.stringValue, !subtitle.isEmpty {
            lines.append("<dc:title>\(OPFDocument.escape(subtitle))</dc:title>")
        }
        if let year = tags[.year]?.intValue {
            lines.append("<dc:date>\(year)</dc:date>")
        }

        // The package's unique-identifier attribute names an identifier element
        // by id, so the id has to survive even when the ISBN changes.
        let identifierID = package.allDC("identifier").first?.attributes["id"]
        if let isbn = tags[.isbn]?.stringValue, !isbn.isEmpty {
            let idAttribute = identifierID.map { " id=\"\(OPFDocument.escape($0))\"" } ?? ""
            lines.append("<dc:identifier\(idAttribute) opf:scheme=\"ISBN\">\(OPFDocument.escape(isbn))</dc:identifier>")
        } else {
            for identifier in package.allDC("identifier") { lines.append(serialise(identifier)) }
        }

        if let series = tags[.series]?.stringValue, !series.isEmpty {
            lines.append("<meta name=\"calibre:series\" content=\"\(OPFDocument.escape(series))\"/>")
            if let index = tags[.seriesIndex]?.intValue {
                lines.append("<meta name=\"calibre:series_index\" content=\"\(index)\"/>")
            }
        }

        return "\n" + lines.joined(separator: "\n") + "\n"
    }

    /// Re-emit an element we are not managing, byte-for-byte in spirit.
    private static func serialise(_ element: OPFDocument.Element) -> String {
        let prefix = element.namespace == OPFDocument.dublinCore ? "dc:" : ""
        let attributes = element.attributes
            .sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(OPFDocument.escape($0.value))\"" }
            .joined()
        if element.text.isEmpty {
            return "<\(prefix)\(element.name)\(attributes)/>"
        }
        return "<\(prefix)\(element.name)\(attributes)>\(OPFDocument.escape(element.text))</\(prefix)\(element.name)>"
    }
}
