import MediaCore

/// ID3v2 frame IDs, as AVFoundation surfaces them for mp3 (`id3/TIT2` …).
/// Read-only for now: writing mp3 means rewriting the tag block ourselves,
/// which AVFoundation will not do. See `docs/ARCHITECTURE.md` phase 5.
enum ID3KeyMap {
    static let frames: [String: TagKey] = [
        "TIT2": .title,
        "TPE1": .artist,
        "TPE2": .albumArtist,
        "TALB": .album,
        "TCON": .genre,
        "TCOM": .composer,
        "TIT1": .grouping,
        "TPUB": .publisher,
        "TYER": .year,        // ID3v2.3
        "TDRC": .year,        // ID3v2.4 recording time
        "TRCK": .trackNumber, // "3/12" — split on write-back
        "TPOS": .discNumber,
        "COMM": .comment,
        "TCMP": .compilation,
        "TSOA": .custom("id3/TSOA"),
    ]

    /// Frames whose value is `index/total`, an ID3 convention with no MPEG-4
    /// equivalent — the reader splits it across two keys.
    static let pairedFrames: [String: (index: TagKey, total: TagKey)] = [
        "TRCK": (.trackNumber, .trackTotal),
        "TPOS": (.discNumber, .discTotal),
    ]

    static let numericKeys: Set<TagKey> = [
        .year, .trackNumber, .trackTotal, .discNumber, .discTotal,
    ]

    /// Frames OmniTag owns on write: everything else in a file is preserved
    /// untouched. v2.4 spellings only — see `supersededFrameIDs`.
    static let writeFrames: [(String, TagKey)] = [
        ("TIT2", .title), ("TPE1", .artist), ("TPE2", .albumArtist),
        ("TALB", .album), ("TCON", .genre), ("TCOM", .composer),
        ("TIT1", .grouping), ("TPUB", .publisher), ("TDRC", .year),
        ("TRCK", .trackNumber), ("TPOS", .discNumber), ("TCMP", .compilation),
    ]

    /// Frames replaced wholesale on write, so a stale value cannot linger.
    static var managedFrameIDs: Set<String> {
        Set(writeFrames.map(\.0)).union(supersededFrameIDs).union(["TXXX"])
    }

    /// v2.3 spellings that v2.4 replaced. Dropped on write so a file never
    /// carries two answers to the same question.
    static let supersededFrameIDs: Set<String> = ["TYER", "TDAT", "TIME", "TRDA"]

    private static let prefix = "id3/"

    static func frameID(fromIdentifier identifier: String) -> String? {
        identifier.hasPrefix(prefix) ? String(identifier.dropFirst(prefix.count)) : nil
    }

    static func key(forIdentifier identifier: String) -> TagKey {
        guard let frame = frameID(fromIdentifier: identifier), let key = frames[frame]
        else { return .custom(identifier) }
        return key
    }

    /// `"3/12"` → `(3, 12)`. A bare `"3"` has no total; anything else is neither.
    static func split(_ value: String) -> (Int?, Int?) {
        let parts = value.split(separator: "/", maxSplits: 1)
        return (parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil)
    }

    /// A year frame may carry a full timestamp (`2017-05-02`); keep the year.
    static func value(_ string: String, for key: TagKey) -> TagValue {
        guard numericKeys.contains(key) else { return .string(string) }
        if let n = Int(string) { return .number(n) }
        if key == .year, let year = Int(string.prefix(4)) { return .number(year) }
        return .string(string)
    }
}
