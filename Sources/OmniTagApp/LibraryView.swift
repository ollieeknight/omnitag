import EditEngine
import MediaCore
import SwiftUI
import TagIO
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: LibraryModel
    // Persisted: the library's folders survive a launch, so the columns you
    // chose to look at them through should too.
    @AppStorage("tableColumns") private var columnsData = ""
    @State private var columns = TableColumnCustomization<MediaItem>()
    @State private var showInspector = true
    /// Non-nil while the removal confirmation is up, holding how many of the
    /// selected files have edits that were never written.
    @State private var pendingRemoval: Int?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if model.visible.isEmpty {
                        emptyState
                    } else {
                        table
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.player.duration > 0 || model.player.currentURL != nil {
                    Divider()
                    playerBar
                }
                if !model.failures.isEmpty {
                    Divider()
                    failureBar
                }
            }
            // Icon-only toolbars make the user guess; every Apple pro app
            // that has more than three actions labels them.
            .toolbarRole(.editor)
            .navigationTitle(model.scope.title)
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 280, ideal: 300, max: 380)
            }
            .confirmationDialog(
                "Discard unsaved changes to ^[\(pendingRemoval ?? 0) file](inflect: true)?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: {
                    if !$0 {
                        pendingRemoval = nil
                    }
                }),
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
            // Re-scan the folders this library was built from. Once, on
            // appear: `.task` is cancelled and re-run on identity change,
            // which a plain window never has.
            .task { await model.restore() }
            // TableColumnCustomization is Codable; @AppStorage cannot hold it
            // directly, so it round-trips through a JSON string.
            .onAppear {
                if let data = columnsData.data(using: .utf8),
                   let saved = try? JSONDecoder().decode(TableColumnCustomization<MediaItem>.self, from: data) {
                    columns = saved
                }
            }
            .onChange(of: columns) {
                if let data = try? JSONEncoder().encode(columns) {
                    columnsData = String(decoding: data, as: UTF8.self)
                }
            }
            .sheet(isPresented: $model.showWizard) {
                MetadataWizardView(items: model.selectedItems, kind: model.kind) { tags, artwork, chapters, clearing, kind in
                    await model.applyWizardSnapshot(
                        tags: tags, artwork: artwork, chapters: chapters, clearing: clearing, reclassifyTo: kind
                    )
                }
                // The wizard's state is seeded from the selection at init, so a
                // new selection has to be a new view, not a reused one.
                .id(model.selection)
            }
            .sheet(isPresented: $model.showBulkEdit) {
                BulkEditSheet(items: model.selectedItems) { await model.edit($0) }
                    .id(model.selection)
            }
            .sheet(isPresented: $model.showRenamer) {
                RenameSheet(
                    items: model.selectedItems, kind: model.kind,
                    rename: { await model.rename($0) },
                    applyTags: { await model.applyParsedTags($0) }
                )
                // Same rule as the wizard: the preview is seeded from the
                // selection, so a new selection has to be a new view.
                .id(model.selection)
            }
        }
        // Inline title beside the toolbar rather than a separate title bar
        // row. (It does not add labels under the icons on macOS 26, so every
        // toolbar button carries a `.help` tooltip naming it and its key.)
        .toolbarRole(.editor)
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

    /// What the window's subtitle says about the current scope. Saving and
    /// failures used to live in a status bar across the bottom; they say more
    /// here, where the eye already is for the title.
    private var subtitle: String {
        if let progress = model.saveProgress {
            return "Saving \(progress.done) of \(progress.total)…"
        }
        let shown = model.visible.count
        var parts = [shown == 1 ? "1 file" : "\(shown) files"]
        if !model.search.isEmpty || model.showUnsavedOnly {
            parts[0] = "\(parts[0]) shown"
        }
        if model.dirtyCount > 0 {
            parts.append("\(model.dirtyCount) unsaved")
        }
        if !model.failures.isEmpty {
            parts.append(model.failures.count == 1 ? "1 failed" : "\(model.failures.count) failed")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Sidebar

    /// `All` first, then the five kinds under a header — the shape Music,
    /// Photos and Mail all use: one row for everything, then the divisions.
    private var sidebar: some View {
        List(selection: $model.scope) {
            sidebarRow(.all)

            Section("Library") {
                ForEach(MediaKind.allCases, id: \.self) { kind in
                    sidebarRow(.kind(kind))
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    @ViewBuilder
    private func sidebarRow(_ scope: LibraryScope) -> some View {
        let count = model.count(for: scope)
        Label {
            Text(scope.title)
        } icon: {
            Image(systemName: scope.symbol)
                .foregroundStyle(scope.tint)
        }
        .badge(count)
        .tag(scope)
        .dropDestination(for: URL.self) { urls, _ in
            // Dropping onto All would mean "no particular kind", which is not
            // a reclassification — only the kind rows accept a drop.
            guard let kind = scope.kind else { return false }
            model.selection = Set(urls)
            Task { await model.setKind(kind) }
            return true
        }
    }

    /// Save state, where the sidebar has room for it. The plain file count
    /// is the window subtitle's job — printing it in both places just made
    /// the same number disagree with itself while a filter was on.
    @ViewBuilder
    private var sidebarFooter: some View {
        if model.dirtyCount > 0 || model.saveProgress != nil {
            VStack(spacing: 0) {
                Divider()
                Group {
                    if let progress = model.saveProgress {
                        ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                            Text("Saving \(progress.done) of \(progress.total)")
                        }
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    } else {
                        Button {
                            Task { await model.save() }
                        } label: {
                            Label("Save ^[\(model.dirtyCount) change](inflect: true)", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                        .help("Write every unsaved change to disk (⌘⇧S)")
                    }
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(
            model.visible, selection: $model.selection,
            sortOrder: $model.sortOrder, columnCustomization: $columns
        ) {
            // A header word that never fits its own column reads as "S…",
            // so the dot speaks for itself and the name lives in the tooltip.
            TableColumn("") { item in
                if model.dirtyURLs.contains(item.url) {
                    Circle()
                        .fill(.blue)
                        .frame(width: 7, height: 7)
                        .help("Unsaved changes")
                        .accessibilityLabel("Unsaved changes")
                }
            }
            .width(16)
            .customizationID("status")

            // Only under All: a mixed table is unreadable without knowing
            // what each row is. A kind tab already answers it in the sidebar.
            TableColumn("Kind", value: \.kindLabel) { item in
                Label {
                    Text(item.kindLabel)
                } icon: {
                    Image(systemName: item.kind.symbol)
                        .foregroundStyle(LibraryScope.kind(item.kind).tint)
                }
                .labelStyle(.titleAndIcon)
                .font(.callout)
            }
            .width(min: 90, ideal: 110, max: 140)
            .customizationID("kind")
            .defaultVisibility(model.scope == .all ? .visible : .hidden)

            TableColumn("Title", value: \.displayTitle) { item in
                HStack(spacing: 8) {
                    coverThumbnail(item)
                    Text(item.displayTitle).lineLimit(1)
                }
            }
            .customizationID("title")

            TableColumn("By", value: \.displayBy) { item in
                Text(item.displayBy.isEmpty ? "—" : item.displayBy)
                    .foregroundStyle(item.displayBy.isEmpty ? .tertiary : .primary)
            }
            .customizationID("by")
            .defaultVisibility(model.scope == .all ? .visible : .hidden)

            TableColumn(model.kind == .music ? "Artist" : "Author", value: \.displayAuthor) { item in
                Text(item.displayAuthor.isEmpty ? "—" : item.displayAuthor)
                    .foregroundStyle(item.displayAuthor.isEmpty ? .tertiary : .primary)
            }
            .customizationID("author")
            // Movies and TV have a director, never an author — the column read
            // "Author" and was empty for every row on those two tabs. Under
            // All the shared "By" column speaks for every kind instead.
            .defaultVisibility(isVideoTab || model.scope == .all ? .hidden : .visible)

            videoColumns

            bookColumns

            TableColumn(model.kind == .book ? "Contents" : "Chapters", value: \.chapterCount) { item in
                Text(item.chapters.isEmpty ? "—" : String(item.chapters.count))
                    .monospacedDigit()
                    .foregroundStyle(item.chapters.isEmpty ? .tertiary : .primary)
            }
            .width(min: 60, ideal: 70, max: 100)
            .customizationID("chapters")
            .defaultVisibility(model.scope == .all ? .hidden : .visible)

            TableColumn("Format", value: \.container.rawValue) { item in
                Text(item.container.rawValue.uppercased())
                    .foregroundStyle(MediaTagReader.canWrite(item.container) ? .primary : .secondary)
            }
            .width(min: 60, ideal: 70, max: 100)
            .customizationID("format")

            TableColumn("Length", value: \.sortableDuration) { item in
                Text(item.duration.map(Self.formatted) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(item.duration == nil ? .tertiary : .primary)
            }
            .width(min: 70, ideal: 80, max: 120)
            .customizationID("length")
            .defaultVisibility(model.scope == .kind(.book) ? .hidden : .visible)
        }
        .contextMenu(forSelectionType: URL.self) { selection in
            contextMenu(for: selection)
        } primaryAction: { selection in
            model.selection = selection
            model.player.togglePlayPause()
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
        .searchable(text: $model.search, prompt: model.scope == .all ? "Search Library" : "Search \(model.scope.title)")
        // Alternating backgrounds paint a stripe for every row the table
        // *could* hold, so one file sat above a dozen empty ghost rows. A
        // plain inset table ends where its content does.
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .frame(minWidth: 480)
    }

    /// Audiobook/book-only columns, split out for the same type-checking
    /// reason as `videoColumns`.
    @TableColumnBuilder<MediaItem, KeyPathComparator<MediaItem>>
    private var bookColumns: some TableColumnContent<MediaItem, KeyPathComparator<MediaItem>> {
        TableColumn("Narrator", value: \.displayNarrator) { item in
            Text(item.displayNarrator.isEmpty ? "—" : item.displayNarrator)
                .foregroundStyle(item.displayNarrator.isEmpty ? .tertiary : .primary)
        }
        .customizationID("narrator")
        .defaultVisibility(model.scope == .kind(.audiobook) ? .visible : .hidden)

        TableColumn(seriesHeading, value: \.displaySeries) { item in
            Text(item.displaySeries.isEmpty ? "—" : item.displaySeries)
                .foregroundStyle(item.displaySeries.isEmpty ? .tertiary : .primary)
        }
        .customizationID("series")
        .defaultVisibility(model.scope == .all ? .hidden : .visible)

        TableColumn("ISBN", value: \.displayISBN) { item in
            Text(item.displayISBN.isEmpty ? "—" : item.displayISBN)
                .font(.callout.monospaced())
                .foregroundStyle(item.displayISBN.isEmpty ? .tertiary : .secondary)
        }
        .width(min: 100, ideal: 120, max: 150)
        .customizationID("isbn")
        .defaultVisibility(model.scope == .kind(.book) ? .visible : .hidden)

        TableColumn("ASIN", value: \.displayASIN) { item in
            Text(item.displayASIN.isEmpty ? "—" : item.displayASIN)
                .font(.callout.monospaced())
                .foregroundStyle(item.displayASIN.isEmpty ? .tertiary : .secondary)
        }
        .width(min: 90, ideal: 110, max: 140)
        .customizationID("asin")
        .defaultVisibility(model.scope == .kind(.audiobook) ? .visible : .hidden)
    }

    /// Movie/TV-only columns, split out of `table` because SwiftUI's column
    /// builder stops type-checking a body this long in reasonable time.
    @TableColumnBuilder<MediaItem, KeyPathComparator<MediaItem>>
    private var videoColumns: some TableColumnContent<MediaItem, KeyPathComparator<MediaItem>> {
        TableColumn("Director", value: \.displayDirector) { item in
            Text(item.displayDirector.isEmpty ? "—" : item.displayDirector)
                .foregroundStyle(item.displayDirector.isEmpty ? .tertiary : .primary)
        }
        .customizationID("director")
        .defaultVisibility(isVideoTab ? .visible : .hidden)

        TableColumn("Episode", value: \.displayEpisode) { item in
            Text(item.displayEpisode.isEmpty ? "—" : item.displayEpisode)
                .font(.callout.monospaced())
                .foregroundStyle(item.displayEpisode.isEmpty ? .tertiary : .primary)
        }
        .width(min: 70, ideal: 80, max: 100)
        .customizationID("episode")
        .defaultVisibility(model.kind == .tvEpisode ? .visible : .hidden)

        TableColumn("Year", value: \.displayYear) { item in
            Text(item.displayYear.isEmpty ? "—" : item.displayYear)
                .monospacedDigit()
                .foregroundStyle(item.displayYear.isEmpty ? .tertiary : .primary)
        }
        .width(min: 50, ideal: 60, max: 80)
        .customizationID("year")
        .defaultVisibility(isVideoTab ? .visible : .hidden)
    }

    /// Movies and TV share a vocabulary the audiobook/book columns do not fit.
    private var isVideoTab: Bool {
        model.scope == .kind(.movie) || model.scope == .kind(.tvEpisode)
    }

    private var seriesHeading: String {
        switch model.kind {
        case .music: "Album"
        case .audiobook, .book: "Series"
        case .movie: "Collection"
        case .tvEpisode: "Show"
        }
    }

    @ViewBuilder
    private func coverThumbnail(_ item: MediaItem) -> some View {
        if let image = model.thumbnails.image(for: item) {
            Image(nsImage: image)
                .resizable().scaledToFill()
                .frame(width: 20, height: 20)
                .clipShape(.rect(cornerRadius: 3))
                .accessibilityHidden(true)
        } else {
            // The file's own kind, not a closed book on top of a film. Tinted
            // to match the sidebar, so a row and its tab are the same colour.
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(width: 20, height: 20)
                .overlay(
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(LibraryScope.kind(item.kind).tint.opacity(0.7))
                )
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
                model.showBulkEdit = true
            } label: {
                Label("Edit Tags…", systemImage: "text.badge.checkmark")
            }
            Button {
                model.selection = selection
                model.showRenamer = true
            } label: {
                Label("Rename from Tags…", systemImage: "textformat.abc")
            }
            Menu("Set Kind") {
                ForEach(MediaKind.allCases, id: \.self) { targetKind in
                    Button {
                        model.selection = selection
                        Task { await model.setKind(targetKind) }
                    } label: {
                        Label(targetKind.title, systemImage: targetKind.symbol)
                    }
                }
            }
            Divider()
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
                    systemImage: "minus.circle"
                )
            }
        }
    }

    /// Three different nothings, and they need three different answers: an
    /// empty library wants a folder, an empty tab wants to say the files are
    /// filed elsewhere, and an empty search wants the search cleared.
    private var emptyState: some View {
        Group {
            if !model.search.isEmpty || model.showUnsavedOnly {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text(filteredEmptyDescription)
                } actions: {
                    if !model.search.isEmpty {
                        Button("Clear Search") { model.search = "" }
                    }
                    if model.showUnsavedOnly {
                        Button("Show All Files") { model.showUnsavedOnly = false }
                    }
                }
            } else if model.items.isEmpty {
                ContentUnavailableView {
                    Label("No Media", systemImage: "square.stack")
                } description: {
                    Text("Drag a folder of music, audiobooks, books, films or TV here — or add one.")
                } actions: {
                    Button("Add Folder…") { model.pickFolder() }
                        .buttonStyle(.borderedProminent)
                    Button("Add Files…") { model.pickFiles() }
                }
            } else {
                // The library has files, just none of this kind — say where
                // they went rather than implying the library is empty.
                ContentUnavailableView {
                    Label("No \(model.scope.title)", systemImage: model.scope.symbol)
                } description: {
                    Text("^[\(model.items.count) file](inflect: true) in the library, filed under other kinds. Drag a row onto \(model.scope.title) to refile it.")
                } actions: {
                    Button("Show All") { model.scope = .all }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.load(urls: urls) }
            return true
        } isTargeted: { model.isDropTarget = $0 }
        .overlay {
            if model.isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
    }

    private var filteredEmptyDescription: String {
        if !model.search.isEmpty, model.showUnsavedOnly {
            return "No unsaved \(model.scope.title.lowercased()) match “\(model.search)”."
        }
        if model.showUnsavedOnly {
            return "Nothing in \(model.scope.title) has unsaved changes."
        }
        return "No \(model.scope.title.lowercased()) match “\(model.search)”."
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Add, then act on what is selected, then filter what is shown, then
        // the inspector — left to right in the order the work happens.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Add Folder…") { model.pickFolder() }
                    .keyboardShortcut("o")
                Button("Add Files…") { model.pickFiles() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                model.pickFolder()
            }
            .help("Add a folder to the library (⌘O)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Get Metadata", systemImage: "wand.and.stars") {
                model.showWizard = true
            }
            .disabled(model.selection.isEmpty || !model.kindHasProvider)
            .keyboardShortcut("l", modifiers: .command)
            .help(metadataHelp)
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Edit Tags…", systemImage: "text.badge.checkmark") {
                model.showBulkEdit = true
            }
            .disabled(model.selection.isEmpty)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Find & replace, case and whitespace transforms (⌘⇧E)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Rename…", systemImage: "square.and.pencil") {
                model.showRenamer = true
            }
            .disabled(model.selection.isEmpty)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Rename the selection from its tags (⌘⇧R)")
        }

        ToolbarSpacer(.flexible)

        ToolbarItem(placement: .primaryAction) {
            Button("Save", systemImage: "square.and.arrow.down") {
                Task { await model.save() }
            }
            .disabled(model.dirtyCount == 0 || model.saveProgress != nil)
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help(model.dirtyCount == 0
                ? "No unsaved changes"
                : "Write ^[\(model.dirtyCount) change](inflect: true) to disk (⌘⇧S)")
        }

        ToolbarItem(placement: .primaryAction) {
            // A filter that is on while its control is off-screen is a trap,
            // so the menu shows a tick and the button stays lit while it bites.
            Menu {
                Toggle("Unsaved Only", isOn: Binding(
                    get: { model.showUnsavedOnly },
                    set: { model.showUnsavedOnly = $0 }
                ))
                .disabled(model.dirtyCount == 0 && !model.showUnsavedOnly)
            } label: {
                Label("Filter", systemImage: model.showUnsavedOnly
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
            }
            .help("Filter what the list shows")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    showInspector.toggle()
                }
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Toggle Inspector (⌘⌥I)")
        }
    }

    private var metadataHelp: String {
        if !model.kindHasProvider {
            return "No metadata provider covers \(model.scope.title) yet"
        }
        return model.selection.isEmpty
            ? "Select files to look up (⌘L)"
            : "Look up the selection online (⌘L)"
    }

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button {
                model.player.togglePlayPause()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.player.isPlaying ? "Pause audio" : "Play audio")

            Button {
                model.player.jump(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Rewind 15 seconds (⌘←)")
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Button {
                model.player.jump(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Fast forward 15 seconds (⌘→)")
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Text(model.player.formattedCurrentTime)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { model.player.progress },
                    set: { model.player.progress = $0 }
                )
            )
            .controlSize(.mini)

            Text(model.player.formattedDuration)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            if model.kind == .audiobook {
                Button {
                    Task { await model.addChapter(at: model.player.currentTime) }
                } label: {
                    Label("Add Marker", systemImage: "bookmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Add chapter at current audio timestamp")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Failures are the one thing the old status bar carried that the window
    /// subtitle cannot: each one names a file and a reason, and the user has
    /// to be able to read them. Counts and progress moved to the subtitle.
    private var failureBar: some View {
        HStack(spacing: 8) {
            Label("^[\(model.failures.count) file](inflect: true) could not be saved", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Spacer()
            Menu("Show Details") {
                ForEach(model.failures, id: \.url) { failure in
                    Text("\(failure.url.lastPathComponent): \(failure.error.localizedDescription)")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button("Dismiss") { model.failures = [] }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    static func formatted(_ seconds: TimeInterval) -> String {
        AudioPlayerModel.format(seconds)
    }
}

// Batch editor. Every field edits the whole selection at once; a field the
// selection disagrees on shows a placeholder rather than silently picking one.
