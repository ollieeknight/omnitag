import EditEngine
import LibraryIndex
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
                Divider()
                Button("Save Changes") { Task { await model.save() } }
                    .keyboardShortcut("s")
                    .disabled(model.dirtyCount == 0)
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
    var selection: Set<URL> = []
    var search = ""
    var status = "No folder loaded"
    var canUndo = false
    var canRedo = false
    var dirtyCount = 0
    var showWizard = false

    private let engine = EditEngine(writer: FileTagWriter())

    var visible: [MediaItem] {
        items.filter { $0.kind == kind }
            .filter { search.isEmpty || $0.searchText.localizedCaseInsensitiveContains(search) }
    }

    var selectedItems: [MediaItem] { visible.filter { selection.contains($0.url) } }

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
                // If it's a directory, scan it. If it's a file, just wrap it if valid.
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    var items = try await scanner.scan(url)
                    // Force the imported items into the currently selected media kind
                    for i in items.indices {
                        items[i].kind = self.kind
                    }
                    scanned.append(contentsOf: items)
                } else if let container = ContainerFormat(pathExtension: url.pathExtension) {
                    scanned.append(MediaItem(url: url, kind: self.kind, container: container, duration: nil, tags: TagSet()))
                }
            }
            
            // Append rather than replace so users can drop multiple times
            var newItems = self.items
            newItems.append(contentsOf: scanned)
            // deduplicate by URL
            var seen = Set<URL>()
            newItems = newItems.filter { seen.insert($0.url).inserted }
            
            self.items = newItems
            status = "\(newItems.count) files — reading tags…"
            
            let reader = MediaTagReader()
            for (index, item) in newItems.enumerated() {
                // Only read if it hasn't been read yet (empty tags/duration). 
                // ponytail: this is a simple heuristic, but good enough for now.
                if item.duration == nil, let read = try? await reader.read(item.url) { 
                    self.items[index] = read 
                }
            }
            await engine.load(self.items)
            await refresh()
            status = "\(self.items.count) files"
        } catch {
            status = "Scan failed: \(error.localizedDescription)"
        }
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
        await engine.applySnapshot(tags: tags, artwork: artwork, chapters: chapters, to: urls)
        await refresh()
    }

    func undo() async { await engine.undo(); await refresh() }
    func redo() async { await engine.redo(); await refresh() }

    func save() async {
        let count = dirtyCount
        status = "Saving \(count) file\(count == 1 ? "" : "s")…"
        do {
            let failures = try await engine.save()
            await refresh()
            status = failures.isEmpty
                ? "Saved \(count) file\(count == 1 ? "" : "s")"
                : "\(failures.count) of \(count) failed: \(failures[0].error.localizedDescription)"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func refresh() async {
        items = await engine.allItems
        canUndo = await engine.canUndo
        canRedo = await engine.canRedo
        dirtyCount = await engine.dirtyURLs.count
    }
}

private extension MediaItem {
    var searchText: String {
        [tags.title, tags.artist, tags.album, tags.author, tags.showName, url.lastPathComponent]
            .compactMap(\.self).joined(separator: " ")
    }
}
