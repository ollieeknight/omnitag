import Foundation
import MediaCore

/// One file's move, decided before anything touches disk.
public struct RenameMove: Sendable, Equatable, Hashable {
    public let from: URL
    public let to: URL

    public init(from: URL, to: URL) {
        self.from = from
        self.to = to
    }
}

/// What a pattern would do to a selection, worked out in full before a single
/// file moves. The preview the user reads and the moves the engine performs are
/// the same values — a preview computed separately is a preview that can lie.
public struct RenamePlan: Sendable {
    public enum Status: Sendable, Equatable {
        /// Will be renamed.
        case ready
        /// Already named this; nothing to do.
        case unchanged
        /// The pattern asked for fields this file does not have.
        case missing([TagKey])
        /// Every field was empty, so there is no name to give it.
        case empty
        /// Another file in this selection wants the same name.
        case collision
        /// A file of that name is already on disk, outside the selection.
        case exists
    }

    public struct Row: Sendable, Identifiable {
        public var id: URL {
            url
        }

        public let url: URL
        public let currentName: String
        /// The name this file would take, extension included. Empty when the
        /// pattern rendered nothing.
        public let newName: String
        public let status: Status
    }

    public let rows: [Row]
    public let moves: [RenameMove]

    public init(items: [MediaItem], pattern: FilenamePattern) {
        var rows: [Row] = []
        var moves: [RenameMove] = []
        // Destination → how many rows want it, so a clash is a property of the
        // batch rather than of whichever file happens to be processed second.
        var wanted: [String: Int] = [:]
        var rendered: [(item: MediaItem, name: String, status: Status)] = []

        for item in items {
            let result = pattern.render(item.tags)
            let ext = item.url.pathExtension
            let name = result.name.isEmpty ? "" : (ext.isEmpty ? result.name : "\(result.name).\(ext)")
            let status: Status = if result.name.isEmpty {
                result.missing.isEmpty ? .empty : .missing(result.missing)
            } else if !result.missing.isEmpty {
                .missing(result.missing)
            } else if name == item.url.lastPathComponent {
                .unchanged
            } else {
                .ready
            }
            if status == .ready {
                wanted[name.lowercased(), default: 0] += 1
            }
            rendered.append((item, name, status))
        }

        for entry in rendered {
            var status = entry.status
            if status == .ready {
                let destination = entry.item.url.deletingLastPathComponent().appending(path: entry.name)
                if wanted[entry.name.lowercased(), default: 0] > 1 {
                    status = .collision
                } else if FileManager.default.fileExists(atPath: destination.path) {
                    status = .exists
                } else {
                    moves.append(RenameMove(from: entry.item.url, to: destination))
                }
            }
            rows.append(Row(
                url: entry.item.url,
                currentName: entry.item.url.lastPathComponent,
                newName: entry.name,
                status: status
            ))
        }

        self.rows = rows
        self.moves = moves
    }
}

public struct RenameOutcome: Sendable {
    public let renamed: Int
    public let failures: [SaveFailure]
    /// The moves that actually happened on disk — a caller remapping its own
    /// state (selection, open player) must follow these, not every move asked for.
    public let done: [RenameMove]
}
