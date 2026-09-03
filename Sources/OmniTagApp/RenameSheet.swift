import EditEngine
import MediaCore
import SwiftUI

/// The two directions Mp3tag calls "Convert": tags into a filename, and a
/// filename back into tags. One sheet, because they share a pattern language
/// and a user who wants one usually wants the other straight afterwards.
struct RenameSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case toFilename = "Tags to Filename"
        case toTags = "Filename to Tags"
        var id: String {
            rawValue
        }
    }

    let items: [MediaItem]
    let kind: MediaKind
    let rename: ([RenameMove]) async -> Void
    let applyTags: ([URL: TagSet]) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .toFilename
    @AppStorage("renamePattern") private var renamePattern = "%artist% - %title%"
    @AppStorage("parsePattern") private var parsePattern = "%artist% - %title%"
    @State private var isApplying = false

    private var pattern: FilenamePattern {
        FilenamePattern(mode == .toFilename ? renamePattern : parsePattern)
    }

    // ponytail: recomputed on every redraw, and it stats one file per row.
    // Fine for a selection you can see; cache it against the pattern if
    // someone renames a thousand files at once and typing drags.
    private var plan: RenamePlan {
        RenamePlan(items: items, pattern: pattern)
    }

    /// One file's name read through the pattern; `tags` is nil when the name
    /// does not match, which is a row the user sees rather than a silent skip.
    private struct ParsedRow: Identifiable {
        var id: URL {
            item.url
        }

        let item: MediaItem
        let tags: TagSet?
    }

    private var parsed: [ParsedRow] {
        items.map { ParsedRow(item: $0, tags: pattern.parse($0.url.lastPathComponent)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if mode == .toFilename {
                    renamePreview
                } else {
                    parsePreview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 460, idealHeight: 560)
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Direction", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                TextField(
                    "Pattern",
                    text: mode == .toFilename ? $renamePattern : $parsePattern,
                    prompt: Text("%artist% - %title%")
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Filename pattern")

                fieldMenu
                presetMenu
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var explanation: String {
        mode == .toFilename
            ? "Files are renamed on disk as soon as you apply. ⌘Z puts the names back."
            : "Parsed values are held as unsaved edits, like any other change, until you save."
    }

    /// Inserting a field beats remembering its spelling, and the list is the
    /// same vocabulary the pattern parser accepts.
    private var fieldMenu: some View {
        Menu {
            ForEach(fieldNames, id: \.self) { name in
                Button("%\(name)%") { insert("%\(name)%") }
            }
        } label: {
            Label("Field", systemImage: "curlybraces")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Insert a field placeholder")
    }

    private var fieldNames: [String] {
        let preferred = TagKey.standardFields(for: kind).map { FilenamePattern.label(for: $0.key) }
        let rest = FilenamePattern.vocabulary.map(\.name).filter { !preferred.contains($0) }
        return preferred.filter { $0 != "field" } + rest
    }

    private var presetMenu: some View {
        Menu {
            ForEach(Self.presets(for: kind), id: \.self) { preset in
                Button(preset) {
                    if mode == .toFilename {
                        renamePattern = preset
                    } else {
                        parsePattern = preset
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    static func presets(for kind: MediaKind) -> [String] {
        switch kind {
        case .music:
            ["%artist% - %title%", "%track% %title%", "%album% - %track% - %title%"]
        case .audiobook:
            ["%author% - %title%", "%series% %seriesindex% - %title%", "%author% - %series% %seriesindex% - %title%"]
        case .book:
            ["%author% - %title%", "%author% - %series% %seriesindex% - %title%"]
        case .movie:
            ["%title% (%year%)", "%title% (%year%) - %director%"]
        case .tvEpisode:
            ["%show% - S%season%E%episode% - %episodetitle%", "S%season%E%episode% - %episodetitle%"]
        }
    }

    private func insert(_ token: String) {
        if mode == .toFilename {
            renamePattern += token
        } else {
            parsePattern += token
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if isApplying {
                ProgressView().controlSize(.small)
            }
            Button(mode == .toFilename ? "Rename" : "Apply Tags") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || actionableCount == 0)
        }
        .padding(16)
    }

    private var actionableCount: Int {
        mode == .toFilename ? plan.moves.count : parsed.filter { $0.tags != nil }.count
    }

    private var summary: String {
        let total = items.count
        switch (mode, actionableCount) {
        case (.toFilename, 0): return "Nothing to rename in \(total) file\(total == 1 ? "" : "s")"
        case let (.toFilename, count): return "\(count) of \(total) will be renamed"
        case (.toTags, 0): return "No filename matches this pattern"
        case let (.toTags, count): return "\(count) of \(total) will be tagged"
        }
    }

    private func apply() {
        isApplying = true
        Task {
            if mode == .toFilename {
                await rename(plan.moves)
            } else {
                await applyTags(Dictionary(
                    uniqueKeysWithValues: parsed.compactMap { row in
                        row.tags.map { (row.item.url, $0) }
                    }
                ))
            }
            isApplying = false
            dismiss()
        }
    }

    // MARK: - Previews

    private var renamePreview: some View {
        Table(plan.rows) {
            TableColumn("Current name") { row in
                Text(row.currentName).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("New name") { row in
                Text(row.newName.isEmpty ? "—" : row.newName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.status == .ready ? .primary : .secondary)
            }
            TableColumn("") { row in
                statusLabel(row.status)
            }
            .width(min: 150, ideal: 190)
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: RenamePlan.Status) -> some View {
        switch status {
        case .ready:
            Label("Rename", systemImage: "arrow.right.circle.fill")
                .foregroundStyle(.blue)
        case .unchanged:
            Label("Already named", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case let .missing(keys):
            Label(
                "No \(keys.map { FilenamePattern.label(for: $0) }.joined(separator: ", "))",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        case .empty:
            Label("Nothing to name it", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .collision:
            Label("Two files, one name", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        case .exists:
            Label("Name already taken", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var parsePreview: some View {
        Table(parsed) {
            TableColumn("Filename") { row in
                Text(row.item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Reads as") { row in
                if let tags = row.tags {
                    Text(describe(tags))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Label("No match", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// The parsed fields in the order the pattern names them, so the preview
    /// reads like the pattern rather than like a dictionary dump.
    private func describe(_ tags: TagSet) -> String {
        pattern.fields.compactMap { key in
            guard let value = tags[key]?.stringValue else { return nil }
            return "\(FilenamePattern.label(for: key)): \(value)"
        }.joined(separator: "  ·  ")
    }
}
