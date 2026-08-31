import Foundation
import MediaCore

public struct LibraryScanner: Sendable {
    public init() {}

    /// Walks `root`, returning one untagged `MediaItem` per recognised file.
    /// Tag reading is a separate, slower pass — the table paints from this.
    public func scan(_ root: URL) async throws -> [MediaItem] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: root])
        }

        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var items: [MediaItem] = []
        while let url = walker.nextObject() as? URL {
            guard let format = ContainerFormat(pathExtension: url.pathExtension),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { continue }
            items.append(MediaItem(url: url, kind: format.defaultKind, container: format))
        }
        return items
    }
}
