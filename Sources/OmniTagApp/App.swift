import EditEngine
import LibraryIndex
import MetadataAPI
import MediaCore
import SwiftUI
import TagIO

@main
struct OmniTagApp: App {
    @State private var model = LibraryModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { model.pickFolder() }
                    .keyboardShortcut("o")
                Button("Add Files…") { model.pickFiles() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Save Selected") { Task { await model.saveSelected() } }
                    .keyboardShortcut("s")
                    .disabled(model.selection.isEmpty || model.saveProgress != nil)
                Button("Save All Changes") { Task { await model.save() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.dirtyCount == 0 || model.saveProgress != nil)
            }
            CommandMenu("Library") {
                Button("Search Metadata…") { model.showWizard = true }
                    .keyboardShortcut("l")
                    .disabled(model.selection.isEmpty || !model.kindHasProvider)
                Button("Rename from Tags…") { model.showRenamer = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selection.isEmpty)
                Button("Set Cover…") { model.pickArtwork() }
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Reveal in Finder") { model.revealSelected() }
                    .keyboardShortcut("r")
                    .disabled(model.selection.isEmpty)
                Button("Remove from Library") { Task { await model.confirmedRemoveSelected() } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { Task { await model.undo() } }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo") { Task { await model.redo() } }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
        }
    }
}

@MainActor @Observable
final class LibraryModel {
    var kind: MediaKind = .music
    var items: [MediaItem] = []
    var selection: Set<URL> = [] {
        didSet {
            if let first = selectedItems.first {
                player.load(url: first.url)
            } else {
                player.stop()
            }
        }
    }
    var search = ""
    var status = "No folder loaded"
    var canUndo = false
    var canRedo = false
    var dirtyCount = 0
    var showWizard = false
    var showRenamer = false
    var isDropTarget = false
    var showUnsavedOnly = false
    /// Which files differ from disk, so the table can mark them one by one
    /// rather than only counting them in the status bar.
    var dirtyURLs: Set<URL> = []
    var saveProgress: (done: Int, total: Int)?
    var failures: [SaveFailure] = []
    var sortOrder = [KeyPathComparator(\MediaItem.displayTitle)]
    let player = AudioPlayerModel()
    private let engine = EditEngine(writer: FileTagWriter())

    // ponytail: filters and sorts on every read, and the table reads it several
    // times per redraw. Cache it against kind/search/sortOrder if a library
    // large enough to stutter while typing ever turns up.
    var visible: [MediaItem] {
        items.filter { $0.kind == kind }
            .filter { showUnsavedOnly ? dirtyURLs.contains($0.url) : true }
            .filter { search.isEmpty || $0.searchText.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var selectedItems: [MediaItem] { visible.filter { selection.contains($0.url) } }

    /// Whether any provider serves the current tab. Movies and TV have none
    /// yet, and the wizard says so rather than opening onto nothing.
    var kindHasProvider: Bool { !MetadataProviders.serving(kind).isEmpty }

    /// Fields shared by the whole selection; anything conflicting reads empty
    /// and shows a "multiple values" placeholder.
    var commonTags: TagSet { TagSet.common(of: selectedItems.map(\.tags)) }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add to Library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url) }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await load(urls: urls) }
    }

    func load(_ root: URL) async {
        await load(urls: [root])
    }

    func load(urls: [URL]) async {
        status = "Scanning \(urls.count) item\(urls.count == 1 ? "" : "s")…"
        do {
            let scanner = LibraryScanner()
            var scanned: [MediaItem] = []
            for url in urls {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                if exists, isDirectory.boolValue {
                    scanned.append(contentsOf: try await scanner.scan(url))
                } else if let container = ContainerFormat(pathExtension: url.pathExtension) {
                    scanned.append(MediaItem(url: url, kind: Self.detectKind(url: url, defaultKind: self.kind), container: container))
                }
            }
            // Smart auto-classifier: assign kind based on format and naming heuristics.
            for index in scanned.indices {
                scanned[index].kind = Self.detectKind(url: scanned[index].url, defaultKind: self.kind)
            }

            // add, never load: load resets the saved baseline and would mark
            // every pending edit as already written.
            await engine.add(scanned)
            await refresh()
            status = "\(items.count) files — reading tags…"

            // ponytail: serial, one file at a time. Fine for hundreds, visible
            // at thousands — switch to a TaskGroup when a real library drags.
            let reader = MediaTagReader()
            for item in scanned {
                guard var read = try? await reader.read(item.url) else { continue }
                read.kind = item.kind
                await engine.refreshFromDisk(read)
            }
            await refresh()
            status = "\(items.count) files"
        } catch {
            status = "Scan failed: \(error.localizedDescription)"
        }
    }

    /// Auto-detects media kind from file extension and filename patterns.
    private static func detectKind(url: URL, defaultKind: MediaKind) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if ext == "m4b" { return .audiobook }
        if ext == "epub" || ext == "pdf" { return .book }
        let name = url.lastPathComponent
        if (ext == "mkv" || ext == "mp4" || ext == "mov" || ext == "m4v") {
            if name.range(of: #"[Ss]\d+[Ee]\d+|\d+x\d+"#, options: .regularExpression) != nil {
                return .tvEpisode
            }
            if defaultKind == .tvEpisode || defaultKind == .movie { return defaultKind }
            return .movie
        }
        return defaultKind
    }

    func setKind(_ newKind: MediaKind) async {
        let urls = Array(selection)
        guard !urls.isEmpty else { return }
        await engine.setKind(newKind, to: urls)
        await refresh()
    }

    func edit(_ edit: TagEdit) async {
        let urls = Array(selection)
        guard !urls.isEmpty else { return }
        await engine.apply(edit, to: urls)
        await refresh()
    }

    func applyWizardSnapshot(tags: TagSet, artwork: [Artwork], chapters: [Chapter]?) async {
        let urls = Array(selection)
        guard !urls.isEmpty else { return }
        let sized = artwork.compactMap { CoverImage.artwork(from: $0.data, role: $0.role) }
        await engine.applySnapshot(tags: tags, artwork: sized, chapters: chapters, to: urls)
        await refresh()
    }

    /// Artwork edits go through the engine like any other change: undoable,
    /// and written only when the user saves.
    func setArtwork(_ artwork: [Artwork]) async {
        let urls = Array(selection)
        guard !urls.isEmpty else { return }
        await engine.setArtwork(artwork, to: urls)
        await refresh()
    }

    /// Reads a dropped or chosen image file, preserving original quality by default.
    func setArtwork(fromFile url: URL) async {
        guard let data = try? Data(contentsOf: url),
              let artwork = CoverImage.artwork(from: data) else {
            status = "\(url.lastPathComponent) is not an image OmniTag can read"
            return
        }
        await setArtwork([artwork])
        status = "Cover set from \(url.lastPathComponent) (\(data.count.formatted(.byteCount(style: .file))))"
    }

    /// Searches the media item's directory for local artwork (cover.jpg, folder.jpg, etc.).
    func findLocalArtwork() async {
        guard let item = selectedItems.first else { return }
        let dir = item.url.deletingLastPathComponent()
        let stem = item.url.deletingPathExtension().lastPathComponent
        let candidates = [
            "cover.jpg", "cover.png", "cover.jpeg",
            "folder.jpg", "folder.png", "albumart.jpg",
            "\(stem).jpg", "\(stem).png", "\(stem).jpeg"
        ]
        for name in candidates {
            let candidateURL = dir.appending(path: name)
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                await setArtwork(fromFile: candidateURL)
                return
            }
        }
        status = "No cover image found in \(dir.lastPathComponent)"
    }

    /// Pastes an image directly from the system clipboard.
    func pasteArtwork() async {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [:]) ?? bitmap.representation(using: .png, properties: [:]),
              let artwork = CoverImage.artwork(from: data)
        else {
            status = "No image on clipboard"
            return
        }
        await setArtwork([artwork])
        status = "Cover pasted from clipboard (\(data.count.formatted(.byteCount(style: .file))))"
    }

    func pickArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Set Cover"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await setArtwork(fromFile: url) }
    }

    // MARK: - Chapter Editing in Main UI

    func applyChapters(_ chapters: [Chapter]) async {
        let urls = Array(selection)
        guard !urls.isEmpty else { return }
        await engine.applyChapters(chapters, to: urls)
        await refresh()
    }

    func addChapter(at time: TimeInterval, title: String? = nil) async {
        guard let item = selectedItems.first else { return }
        var chapters = item.chapters
        let nextIndex = chapters.count
        let newTitle = title ?? "Chapter \(nextIndex + 1)"
        chapters.append(Chapter(index: nextIndex, start: time, title: newTitle))
        chapters.sort { $0.start < $1.start }
        for i in chapters.indices { chapters[i].index = i }
        await applyChapters(chapters)
    }

    func updateChapter(index: Int, title: String, start: TimeInterval) async {
        guard let item = selectedItems.first, index < item.chapters.count else { return }
        var chapters = item.chapters
        chapters[index].title = title
        chapters[index].start = max(0, start)
        chapters.sort { $0.start < $1.start }
        for i in chapters.indices { chapters[i].index = i }
        await applyChapters(chapters)
    }

    func removeChapter(at index: Int) async {
        guard let item = selectedItems.first, index < item.chapters.count else { return }
        var chapters = item.chapters
        chapters.remove(at: index)
        for i in chapters.indices { chapters[i].index = i }
        await applyChapters(chapters)
    }

    // MARK: - Filenames

    /// Renames files on disk and follows them: the selection, the working set,
    /// and the undo history all move to the new URLs. Unlike a tag edit this is
    /// not deferred to a save — there is no such thing as a half-renamed file.
    func rename(_ moves: [RenameMove]) async {
        guard !moves.isEmpty else { return }
        let outcome = await engine.rename(moves)
        let table = Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { _, last in last })
        selection = Set(selection.map { table[$0] ?? $0 })
        // The player holds a URL that no longer exists; reloading it keeps the
        // transport bar pointing at the file the user can still see.
        if let playing = player.currentURL, let moved = table[playing] {
            player.stop()
            player.load(url: moved)
        }
        await refresh()
        status = outcome.failures.isEmpty
            ? "Renamed \(outcome.renamed) file\(outcome.renamed == 1 ? "" : "s")"
            : "Renamed \(outcome.renamed), \(outcome.failures.count) failed — \(outcome.failures.first?.error.localizedDescription ?? "")"
    }

    /// Writes what the filename parser read, one delta per file, as a single
    /// undoable batch. Held in memory like any other edit until the user saves.
    func applyParsedTags(_ deltas: [URL: TagSet]) async {
        guard !deltas.isEmpty else { return }
        await engine.applyTagDeltas(deltas)
        await refresh()
        status = "Tagged \(deltas.count) file\(deltas.count == 1 ? "" : "s") from their names — not yet saved"
    }

    /// Edits among the selection that are not yet on disk. Removal cannot be
    /// undone, so the view asks before throwing these away.
    func unsavedInSelection() async -> Int {
        await engine.unsavedCount(among: Array(selection))
    }

    /// The menu-bar route to removal. It runs the same guard the context menu
    /// does, via an alert rather than a sheet-owned dialog.
    func confirmedRemoveSelected() async {
        let unsaved = await unsavedInSelection()
        guard unsaved > 0 else { return await removeSelected() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(unsaved) file\(unsaved == 1 ? " has" : "s have") unsaved changes"
        alert.informativeText = "Removing them discards those edits. The files on disk are not touched, and this cannot be undone."
        alert.addButton(withTitle: "Remove Anyway")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await removeSelected()
    }

    /// Drops files from the library. The files themselves are never touched —
    /// this is a view of a folder, not a manager of it.
    func removeSelected() async {
        let urls = Array(selection)
        guard !urls.isEmpty else { return }
        await engine.remove(urls)
        selection = []
        await refresh()
        status = "\(items.count) files"
    }

    func revealSelected() {
        NSWorkspace.shared.activateFileViewerSelecting(Array(selection))
    }

    func undo() async { await engine.undo(); await refresh() }
    func redo() async { await engine.redo(); await refresh() }

    func saveSelected() async {
        let selectedDirty = dirtyURLs.intersection(selection)
        guard !selectedDirty.isEmpty else { return }
        await save(only: selectedDirty)
    }

    func save(only selection: Set<URL>? = nil) async {
        let pending = selection != nil ? dirtyURLs.intersection(selection!) : dirtyURLs
        let count = pending.count
        guard count > 0 else { return }
        failures = []
        saveProgress = (0, count)
        status = "Saving \(count) file\(count == 1 ? "" : "s")…"
        defer { saveProgress = nil }
        do {
            let written = try await engine.save(only: selection) { [weak self] _, done, total in
                Task { @MainActor in self?.saveProgress = (done, total) }
            }
            failures = written
            await refresh()
            status = written.isEmpty
                ? "Saved \(count) file\(count == 1 ? "" : "s")"
                : "\(written.count) of \(count) failed — see the warning for details"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func refresh() async {
        items = await engine.allItems
        canUndo = await engine.canUndo
        canRedo = await engine.canRedo
        let dirty = await engine.dirtyURLs
        dirtyURLs = Set(dirty)
        dirtyCount = dirty.count
    }
}

/// Non-optional, sortable views of a tag set. `KeyPathComparator` needs a
/// `Comparable` value, and `String?` is not one — every column that sorts has
/// to name a property like these.
extension MediaItem {
    var searchText: String {
        [tags.title, tags.artist, tags.album, tags.author, tags.showName,
         tags[.narrator]?.stringValue, tags[.asin]?.stringValue, url.lastPathComponent]
            .compactMap(\.self).joined(separator: " ")
    }
    var displayTitle: String { tags.title ?? url.deletingPathExtension().lastPathComponent }
    var displayArtist: String { tags.artist ?? tags.author ?? "" }
    var displayAuthor: String { tags.author ?? tags.artist ?? "" }
    var displayNarrator: String { tags[.narrator]?.stringValue ?? "" }
    var displaySeries: String { tags.showName ?? tags[.series]?.stringValue ?? tags.album ?? "" }
    var displaySeriesIndex: Int { tags[.seriesIndex]?.intValue ?? 0 }
    var displayASIN: String { tags[.asin]?.stringValue ?? "" }
    var displayISBN: String { tags[.isbn]?.stringValue ?? "" }
    var chapterCount: Int { chapters.count }
    var sortableDuration: TimeInterval { duration ?? 0 }
}
