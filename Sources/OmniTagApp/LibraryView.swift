import EditEngine
import MediaCore
import SwiftUI
import TagIO

struct LibraryView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            List(MediaKind.allCases, id: \.self, selection: $model.kind) { kind in
                Label(kind.title, systemImage: kind.symbol).tag(kind)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            HSplitView {
                table
                InspectorView(model: model)
                    .frame(minWidth: 280, idealWidth: 320)
            }
            .navigationTitle("OmniTag")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { statusBar }
        }
    }

    private var table: some View {
        Table(model.visible, selection: $model.selection) {
            TableColumn("Title") { item in
                Text(item.tags.title ?? item.url.deletingPathExtension().lastPathComponent)
            }
            TableColumn(model.kind == .music ? "Artist" : "Author") { item in
                Text(item.tags.artist ?? item.tags.author ?? "—")
            }
            TableColumn(model.kind == .tvEpisode ? "Show" : "Album / Series") { item in
                Text(item.tags.showName ?? item.tags.album ?? item.tags[.series]?.stringValue ?? "—")
            }
            TableColumn("Chapters") { item in
                Text(item.chapters.isEmpty ? "—" : String(item.chapters.count))
                    .monospacedDigit()
            }
            TableColumn("Format") { Text($0.container.rawValue.uppercased()) }
            TableColumn("Length") { Text($0.duration.map(Self.formatted) ?? "—").monospacedDigit() }
        }
        .searchable(text: $model.search, prompt: "Search library")
        .frame(minWidth: 480)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Add Folder", systemImage: "folder.badge.plus") { model.pickFolder() }
            Button("Undo", systemImage: "arrow.uturn.backward") { Task { await model.undo() } }
                .disabled(!model.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { Task { await model.redo() } }
                .disabled(!model.canRedo)
            Button("Save", systemImage: "square.and.arrow.down") { Task { await model.save() } }
                .disabled(model.dirtyCount == 0)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.status)
            Spacer()
            if model.dirtyCount > 0 {
                Text("\(model.dirtyCount) unsaved")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    static func formatted(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }
}

/// Batch editor. Every field edits the whole selection at once; a field the
/// selection disagrees on shows a placeholder rather than silently picking one.
struct InspectorView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Form {
            if model.selection.isEmpty {
                ContentUnavailableView(
                    "No Selection", systemImage: "square.dashed",
                    description: Text("Select files to edit their tags."))
            } else {
                if !readOnlySelection.isEmpty {
                    Label(
                        "\(readOnlySelection.count) selected file\(readOnlySelection.count == 1 ? " has" : "s have") no writer yet — edits cannot be saved.",
                        systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Section(header: Text(header)) {
                    ForEach(fields, id: \.key) { field in
                        TagField(key: field.key, label: field.label, model: model)
                    }
                }
                if let chapters = singleSelection?.chapters, !chapters.isEmpty {
                    Section("Chapters (\(chapters.count))") {
                        ForEach(chapters) { chapter in
                            HStack {
                                Text(LibraryView.formatted(chapter.start))
                                    .monospacedDigit().foregroundStyle(.secondary)
                                Text(chapter.title).lineLimit(1)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Files the user can edit on screen but not save: mkv, mp3, flac today.
    private var readOnlySelection: [MediaItem] {
        model.selectedItems.filter { !MediaTagReader.canWrite($0.container) }
    }

    private var singleSelection: MediaItem? {
        model.selectedItems.count == 1 ? model.selectedItems.first : nil
    }

    private var header: String {
        model.selection.count == 1
            ? (singleSelection?.url.lastPathComponent ?? "")
            : "\(model.selection.count) files selected"
    }

    /// Field set per media type — same UX, different vocabulary.
    private var fields: [(key: TagKey, label: String)] {
        switch model.kind {
        case .music:
            [(.title, "Title"), (.artist, "Artist"), (.albumArtist, "Album Artist"),
             (.album, "Album"), (.genre, "Genre"), (.year, "Year"),
             (.trackNumber, "Track"), (.trackTotal, "of"), (.composer, "Composer")]
        case .audiobook:
            [(.title, "Title"), (.author, "Author"), (.narrator, "Narrator"),
             (.series, "Series"), (.seriesIndex, "Book #"), (.publisher, "Publisher"),
             (.year, "Year"), (.genre, "Genre"), (.asin, "ASIN")]
        case .movie:
            [(.title, "Title"), (.year, "Year"), (.director, "Director"),
             (.studio, "Studio"), (.genre, "Genre"), (.contentRating, "Rating"),
             (.synopsis, "Synopsis")]
        case .tvEpisode:
            [(.showName, "Show"), (.seasonNumber, "Season"), (.episodeNumber, "Episode"),
             (.episodeTitle, "Episode Title"), (.year, "Year"), (.director, "Director"),
             (.genre, "Genre")]
        }
    }
}

/// One tag field bound to the whole selection. Commits on Return or focus loss,
/// never per keystroke — a keystroke-level undo stack would be useless for batches.
private struct TagField: View {
    let key: TagKey
    let label: String
    @Bindable var model: LibraryModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var shared: String? { model.commonTags[key]?.stringValue }
    private var isMixed: Bool { shared == nil && model.selection.count > 1 }

    var body: some View {
        TextField(label, text: $text, prompt: Text(isMixed ? "Multiple values" : label))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: shared, initial: true) { _, value in if !focused { text = value ?? "" } }
            .onChange(of: model.selection) { _, _ in text = shared ?? "" }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed != (shared ?? "") else { return }
        Task {
            await model.edit(trimmed.isEmpty ? .clear(key) : .set(key, value(from: trimmed)))
        }
    }

    private func value(from string: String) -> TagValue {
        if let number = Int(string), MPEG4NumericKeys.contains(key) { return .number(number) }
        return .string(string)
    }
}

/// Keys the file formats store as integers. Kept next to the field that needs
/// it rather than exported from TagIO — the UI is the only caller.
private let MPEG4NumericKeys: Set<TagKey> = [
    .year, .trackNumber, .trackTotal, .discNumber, .discTotal,
    .seriesIndex, .seasonNumber, .episodeNumber,
]

extension MediaKind {
    var title: String {
        switch self {
        case .music: "Music"
        case .audiobook: "Audiobooks"
        case .movie: "Movies"
        case .tvEpisode: "TV Shows"
        }
    }
    var symbol: String {
        switch self {
        case .music: "music.note"
        case .audiobook: "headphones"
        case .movie: "film"
        case .tvEpisode: "tv"
        }
    }
}
