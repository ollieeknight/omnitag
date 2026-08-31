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

    func load(_ root: URL) async {
        status = "Scanning \(root.lastPathComponent)…"
        do {
            let scanned = try await LibraryScanner().scan(root)
            items = scanned
            status = "\(scanned.count) files — reading tags…"
            // ponytail: serial read, one file at a time. Swap for a TaskGroup
            // when a real library (10k+ files) makes the wait visible.
            let reader = MediaTagReader()
            for (index, item) in scanned.enumerated() {
                if let read = try? await reader.read(item.url) { items[index] = read }
            }
            await engine.load(items)
            await refresh()
            status = "\(items.count) files"
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
