import Foundation

/// The folders the user has added, remembered between launches.
///
/// Plain file URLs in `UserDefaults`, not security-scoped bookmarks: OmniTag
/// is not sandboxed (see `DECISIONS.md`), so it can reopen a path it was given
/// without one. Bookmarks become mandatory only if the app is ever sandboxed
/// for the App Store.
///
/// Only the *roots* are stored, never the scanned library. A rescan on launch
/// is fast and is the only version that can be right: files move, get retagged
/// by other tools, and get deleted while the app is closed, so a serialised
/// item list would be a cache that is wrong more often than it is useful.
/// Holds the *name* of its defaults suite rather than the `UserDefaults`
/// object, which is not `Sendable`. Resolving it per call is free (the object
/// is a shared singleton per suite) and keeps this a value type the model can
/// hand across actors.
struct LibraryRootStore: Sendable {
    private let suiteName: String?
    private let key = "libraryRoots"

    /// `nil` means the standard suite. Tests pass their own scratch suite so
    /// they never read or write the developer's real preferences.
    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    var roots: [URL] {
        (defaults.array(forKey: key) as? [String] ?? []).map { URL(filePath: $0) }
    }

    /// The remembered roots that are still on disk. A folder the user moved or
    /// deleted between launches is dropped rather than failing a scan on every
    /// launch forever.
    var existingRoots: [URL] {
        roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Appends whatever is new, preserving the order they were added in.
    func remember(_ urls: [URL]) {
        var known = roots
        for url in urls where !known.contains(url) {
            known.append(url)
        }
        defaults.set(known.map(\.path), forKey: key)
    }

    func forgetAll() {
        defaults.removeObject(forKey: key)
    }
}
