import MediaCore
import SwiftUI

/// What the sidebar is pointed at: the whole library, or one media kind.
///
/// `All` is not a sixth `MediaKind` — a file is never *of* kind "all", and
/// making it one would leak into `detectKind`, the key maps and every switch
/// over `MediaKind` in the app. It is a view onto the library, so it lives
/// here instead.
enum LibraryScope: Hashable, Identifiable, CaseIterable {
    case all
    case kind(MediaKind)

    static var allCases: [LibraryScope] {
        [.all] + MediaKind.allCases.map(LibraryScope.kind)
    }

    var id: Self {
        self
    }

    /// The kind this scope filters to, or `nil` for the whole library.
    var kind: MediaKind? {
        switch self {
        case .all: nil
        case let .kind(kind): kind
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case let .kind(kind): kind.title
        }
    }

    /// Singular, for a sentence about one file ("No movie matches…").
    var singular: String {
        switch kind {
        case nil: "file"
        case .music: "track"
        case .audiobook: "audiobook"
        case .book: "book"
        case .movie: "movie"
        case .tvEpisode: "episode"
        }
    }

    /// What one file of this kind is called, capitalised for a table cell.
    /// The sidebar names a *collection* ("TV Shows"); a row names one thing.
    var rowLabel: String {
        switch kind {
        case nil: "File"
        case .music: "Music"
        case .audiobook: "Audiobook"
        case .book: "Book"
        case .movie: "Movie"
        case .tvEpisode: "Episode"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack"
        case let .kind(kind): kind.symbol
        }
    }

    /// Each kind gets its own hue in the sidebar, the way Finder tags and
    /// Mail mailboxes do — colour is what makes a five-row list scannable
    /// without reading it.
    var tint: Color {
        switch kind {
        case nil: .secondary
        case .music: .pink
        case .audiobook: .orange
        case .book: .green
        case .movie: .purple
        case .tvEpisode: .blue
        }
    }
}
