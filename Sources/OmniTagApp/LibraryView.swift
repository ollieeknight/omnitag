import EditEngine
import MediaCore
import SwiftUI
import TagIO
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var columns = TableColumnCustomization<MediaItem>()
    /// Non-nil while the removal confirmation is up, holding how many of the
    /// selected files have edits that were never written.
    @State private var pendingRemoval: Int?

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
                    .frame(minWidth: 300, idealWidth: 340)
            }
            .navigationTitle(model.kind.title)
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .overlay(alignment: .bottom) { statusBar }
            .confirmationDialog(
                "Discard unsaved changes to ^[\(pendingRemoval ?? 0) file](inflect: true)?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove Anyway", role: .destructive) {
                    pendingRemoval = nil
                    Task { await model.removeSelected() }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("Removing them discards those edits. The files on disk are not touched, and this cannot be undone.")
            }
            .sheet(isPresented: $model.showWizard) {
                MetadataWizardView(items: model.selectedItems, kind: model.kind) { tags, artwork, chapters in
                    await model.applyWizardSnapshot(tags: tags, artwork: artwork, chapters: chapters)
                }
                // The wizard's state is seeded from the selection at init, so a
                // new selection has to be a new view, not a reused one.
                .id(model.selection)
            }
        }
    }

    /// Removal purges the undo stack, so unsaved work gets a prompt. Files with
    /// nothing pending are removed straight away — a dialog for those is noise.
    private func confirmRemoval() async {
        let unsaved = await model.unsavedInSelection()
        if unsaved == 0 {
            await model.removeSelected()
        } else {
            pendingRemoval = unsaved
        }
    }

    private var subtitle: String {
        let shown = model.visible.count
        if model.dirtyCount > 0 { return "\(shown) shown · \(model.dirtyCount) unsaved" }
        return shown == 1 ? "1 file" : "\(shown) files"
    }

    // MARK: - Table

    private var table: some View {
        Table(
            model.visible, selection: $model.selection,
            sortOrder: $model.sortOrder, columnCustomization: $columns
        ) {
            TableColumn("Title", value: \.displayTitle) { item in
                HStack(spacing: 8) {
                    coverThumbnail(item)
                    Text(item.displayTitle).lineLimit(1)
                    if model.dirtyURLs.contains(item.url) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
            }
            .customizationID("title")

            TableColumn(model.kind == .music ? "Artist" : "Author", value: \.displayAuthor) { item in
                Text(item.displayAuthor.isEmpty ? "—" : item.displayAuthor)
                    .foregroundStyle(item.displayAuthor.isEmpty ? .tertiary : .primary)
            }
            .customizationID("author")

            TableColumn("Narrator", value: \.displayNarrator) { item in
                Text(item.displayNarrator.isEmpty ? "—" : item.displayNarrator)
                    .foregroundStyle(item.displayNarrator.isEmpty ? .tertiary : .primary)
            }
            .customizationID("narrator")
            .defaultVisibility(model.kind == .audiobook ? .visible : .hidden)

            TableColumn(seriesHeading, value: \.displaySeries) { item in
                Text(item.displaySeries.isEmpty ? "—" : item.displaySeries)
                    .foregroundStyle(item.displaySeries.isEmpty ? .tertiary : .primary)
            }
            .customizationID("series")

            TableColumn("ISBN", value: \.displayISBN) { item in
                Text(item.displayISBN.isEmpty ? "—" : item.displayISBN)
                    .font(.callout.monospaced())
                    .foregroundStyle(item.displayISBN.isEmpty ? .tertiary : .secondary)
            }
            .width(120)
            .customizationID("isbn")
            .defaultVisibility(model.kind == .book ? .visible : .hidden)

            TableColumn("ASIN", value: \.displayASIN) { item in
                Text(item.displayASIN.isEmpty ? "—" : item.displayASIN)
                    .font(.callout.monospaced())
                    .foregroundStyle(item.displayASIN.isEmpty ? .tertiary : .secondary)
            }
            .width(110)
            .customizationID("asin")
            .defaultVisibility(model.kind == .audiobook ? .visible : .hidden)

            TableColumn(model.kind == .book ? "Contents" : "Chapters", value: \.chapterCount) { item in
                Text(item.chapters.isEmpty ? "—" : String(item.chapters.count))
                    .monospacedDigit()
                    .foregroundStyle(item.chapters.isEmpty ? .tertiary : .primary)
            }
            .width(70)
            .customizationID("chapters")

            TableColumn("Format", value: \.container.rawValue) { item in
                Text(item.container.rawValue.uppercased())
                    .foregroundStyle(MediaTagReader.canWrite(item.container) ? .primary : .secondary)
            }
            .width(70)
            .customizationID("format")

            TableColumn("Length", value: \.sortableDuration) { item in
                Text(item.duration.map(Self.formatted) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(item.duration == nil ? .tertiary : .primary)
            }
            .width(80)
            .customizationID("length")
            .defaultVisibility(model.kind == .book ? .hidden : .visible)
        }
        .contextMenu(forSelectionType: URL.self) { selection in
            contextMenu(for: selection)
        } primaryAction: { selection in
            model.selection = selection
            model.revealSelected()
        }
        .overlay {
            if model.visible.isEmpty { emptyState }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.load(urls: urls) }
            return true
        } isTargeted: { model.isDropTarget = $0 }
        .overlay {
            if model.isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.isDropTarget)
        .searchable(text: $model.search, prompt: "Search library")
        .frame(minWidth: 520)
    }

    private var seriesHeading: String {
        switch model.kind {
        case .music: "Album"
        case .audiobook, .book: "Series"
        case .movie: "Collection"
        case .tvEpisode: "Show"
        }
    }

    /// ponytail: decodes on every cell redraw. Cache by URL if a library big
    /// enough to make scrolling stutter ever turns up.
    @ViewBuilder
    private func coverThumbnail(_ item: MediaItem) -> some View {
        if let data = item.artwork.first?.data, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(.rect(cornerRadius: 3))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(width: 20, height: 20)
                .overlay(Image(systemName: "book.closed").font(.system(size: 9)).foregroundStyle(.tertiary))
                .accessibilityLabel("No cover")
        }
    }

    @ViewBuilder
    private func contextMenu(for selection: Set<URL>) -> some View {
        if !selection.isEmpty {
            if model.kindHasProvider {
                Button {
                    model.selection = selection
                    model.showWizard = true
                } label: {
                    Label("Search Metadata…", systemImage: "wand.and.stars")
                }
            }
            Button {
                model.selection = selection
                model.revealSelected()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Divider()
            Button {
                model.selection = selection
                Task { await confirmRemoval() }
            } label: {
                Label(
                    selection.count == 1 ? "Remove from Library" : "Remove \(selection.count) from Library",
                    systemImage: "minus.circle")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.items.isEmpty ? "No Files" : "Nothing Matches",
                  systemImage: model.items.isEmpty ? "square.dashed" : "magnifyingglass")
        } description: {
            Text(model.items.isEmpty
                 ? "Drag a folder here, or use Import. Files land in the \(model.kind.title) tab you are looking at."
                 : "No \(model.kind.title.lowercased()) match “\(model.search)”.")
        } actions: {
            if model.items.isEmpty {
                Button("Add Folder…") { model.pickFolder() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .background(.background)
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Search Metadata", systemImage: "wand.and.stars") {
                model.showWizard = true
            }
            .disabled(model.selection.isEmpty || !model.kindHasProvider)
            .help(model.kindHasProvider
                  ? "Look the selection up online (⌘L)"
                  : "No metadata provider covers \(model.kind.title) yet")
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Add Folder…", systemImage: "folder.badge.plus") { model.pickFolder() }
                Button("Add Files…", systemImage: "doc.badge.plus") { model.pickFiles() }
            } label: {
                Label("Import", systemImage: "plus")
            }
            .help("Import files or folders")
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(placement: .automatic) {
            Button("Undo", systemImage: "arrow.uturn.backward") { Task { await model.undo() } }
                .disabled(!model.canUndo)
                .help("Undo last edit")
        }

        ToolbarItem(placement: .automatic) {
            Button("Redo", systemImage: "arrow.uturn.forward") { Task { await model.redo() } }
                .disabled(!model.canRedo)
                .help("Redo")
        }

        ToolbarSpacer(.flexible)

        ToolbarItem(placement: .confirmationAction) {
            Button("Save", systemImage: "square.and.arrow.down") { Task { await model.save() } }
                .disabled(model.dirtyCount == 0 || model.saveProgress != nil)
                .help(model.dirtyCount == 0 ? "Nothing to save" : "Write \(model.dirtyCount) file(s) to disk")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let progress = model.saveProgress {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(progress.done) of \(progress.total)")
                    .monospacedDigit()
            }

            Text(model.status)

            if !model.failures.isEmpty {
                Divider().frame(height: 14)
                Menu {
                    ForEach(model.failures, id: \.url) { failure in
                        Text("\(failure.url.lastPathComponent): \(failure.error.localizedDescription)")
                    }
                } label: {
                    Label("^[\(model.failures.count) failure](inflect: true)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if model.dirtyCount > 0, model.saveProgress == nil {
                Divider().frame(height: 14)
                Text("^[\(model.dirtyCount) unsaved change](inflect: true)")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular)
        .padding(.bottom, 16)
        .animation(.easeOut(duration: 0.2), value: model.dirtyCount)
    }

    static func formatted(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }
}

/// Batch editor. Every field edits the whole selection at once; a field the
/// selection disagrees on shows a placeholder rather than silently picking one.
struct InspectorView: View {
    @Bindable var model: LibraryModel
    @State private var isArtworkTargeted = false

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

                artworkSection

                Section(header: Text(header)) {
                    ForEach(fields, id: \.key) { field in
                        TagField(key: field.key, label: field.label, model: model)
                    }
                }

                chapterSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Artwork

    /// The cover is the one tag people judge a library by, so it gets a well
    /// rather than a text field: drop an image on it, or use the menu.
    private var artworkSection: some View {
        Section(model.kind == .book && !canEditArtwork ? "Preview" : "Cover") {
            VStack(spacing: 10) {
                artworkWell
                if !canEditArtwork {
                    Text(artworkExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Choose…") { model.pickArtwork() }
                        .disabled(!canEditArtwork)
                    if commonArtwork != nil, canEditArtwork {
                        Button("Remove", role: .destructive) { Task { await model.setArtwork([]) } }
                    }
                    Spacer()
                    if let artwork = commonArtwork {
                        Text("\(artwork.mimeType.replacingOccurrences(of: "image/", with: "").uppercased()) · \(byteCount(artwork.data.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var artworkWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.35))
            if let data = commonArtwork?.data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 10))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: mixedArtwork ? "photo.on.rectangle.angled" : "photo")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text(mixedArtwork ? "Multiple covers" : (canEditArtwork ? "Drop an image" : "No cover"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isArtworkTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isArtworkTargeted ? 3 : 1, dash: commonArtwork == nil ? [6] : []))
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard canEditArtwork, let first = urls.first else { return false }
            Task { await model.setArtwork(fromFile: first) }
            return true
        } isTargeted: { isArtworkTargeted = $0 && canEditArtwork }
        .animation(.easeOut(duration: 0.15), value: isArtworkTargeted)
        .accessibilityLabel(commonArtwork == nil ? "No cover. Drop an image to set one." : "Cover art")
    }

    /// Whether every selected file can actually take a new cover.
    private var canEditArtwork: Bool {
        !model.selectedItems.isEmpty
            && model.selectedItems.allSatisfy { MediaTagReader.canWriteArtwork($0.container) }
    }

    private var artworkExplanation: String {
        if model.selectedItems.contains(where: { $0.container == .pdf }) {
            return "This is page one, rendered. A PDF has nowhere to store a cover."
        }
        if model.selectedItems.contains(where: { $0.container == .epub }) {
            return "This EPUB has no cover image to replace — adding one would mean rewriting its manifest."
        }
        return "The selected format has no writable artwork yet."
    }

    /// The cover the whole selection agrees on, if any.
    private var commonArtwork: Artwork? {
        let covers = model.selectedItems.map(\.artwork.first)
        guard let first = covers.first ?? nil, covers.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private var mixedArtwork: Bool {
        model.selectedItems.count > 1 && model.selectedItems.contains { !$0.artwork.isEmpty }
    }

    private func byteCount(_ bytes: Int) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    // MARK: - Chapters

    @ViewBuilder
    private var chapterSection: some View {
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
                if model.kindHasProvider {
                    Button("Edit in Metadata Wizard…") { model.showWizard = true }
                        .font(.caption)
                }
            }
        }
    }

    /// Files the user can edit on screen but not save: mkv, flac today.
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
            [(.title, "Title"), (.subtitle, "Subtitle"), (.author, "Author"),
             (.narrator, "Narrator"), (.series, "Series"), (.seriesIndex, "Book #"),
             (.publisher, "Publisher"), (.year, "Year"), (.genre, "Genre"),
             (.asin, "ASIN"), (.synopsis, "Summary")]
        case .book:
            [(.title, "Title"), (.subtitle, "Subtitle"), (.author, "Author"),
             (.series, "Series"), (.seriesIndex, "Book #"), (.publisher, "Publisher"),
             (.year, "Year"), (.genre, "Subjects"), (.language, "Language"),
             (.isbn, "ISBN"), (.synopsis, "Description")]
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
        TextField(label, text: $text, prompt: Text(isMixed ? "Multiple values" : label), axis: axis)
            .lineLimit(key == .synopsis ? 2...8 : 1...1)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: shared, initial: true) { _, value in if !focused { text = value ?? "" } }
            .onChange(of: model.selection) { _, _ in text = shared ?? "" }
    }

    private var axis: Axis { key == .synopsis ? .vertical : .horizontal }

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
        case .book: "Books"
        case .movie: "Movies"
        case .tvEpisode: "TV Shows"
        }
    }
    var symbol: String {
        switch self {
        case .music: "music.note"
        case .audiobook: "headphones"
        case .book: "book"
        case .movie: "film"
        case .tvEpisode: "tv"
        }
    }
}
