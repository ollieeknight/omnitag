import Foundation
import MediaCore
import MetadataAPI

@MainActor @Observable
public final class MetadataWizardModel {
    public enum WizardStep: Int, CaseIterable, Identifiable, Comparable {
        case search = 0
        case tags
        case chapters
        case summary

        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .search: "Find"
            case .tags: "Tags"
            case .chapters: "Chapters"
            case .summary: "Apply"
            }
        }

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public enum SearchState {
        case idle
        case searching
        case results([MetadataCandidate])
        /// Distinct from `.error`: the search worked, the catalogue had nothing.
        case empty(String)
        case loadingDetails(MetadataCandidate)
        case error(String)
    }

    public var step: WizardStep = .search
    public var searchState: SearchState = .idle
    public var region: AudibleRegion = .unitedKingdom {
        didSet { if region != oldValue { rebuildProviders() } }
    }

    /// The providers serving this tab, and the one in use. The wizard never
    /// names a service itself — a book tab simply has different providers in it.
    public private(set) var providers: [any MetadataProvider] = []
    public var provider: (any MetadataProvider)?
    public let kind: MediaKind

    public var query = MetadataQuery()
    public var selectedItems: [MediaItem]

    public var candidate: MetadataCandidate?
    public var details: MetadataDetails?

    public var tagDiff = TagDiff(current: TagSet(), proposed: TagSet())
    public var selectedTagKeys: Set<TagKey> = []

    /// The pairing as the provider returned it. `chapterDiff` is this with a
    /// strategy applied and the user's edits on top, so switching strategy
    /// twice does not compound.
    private var baseChapterDiff = ChapterDiff(current: [], proposed: [])
    public var chapterDiff = ChapterDiff(current: [], proposed: [])
    public var chapterStrategy: ChapterDiff.MergeStrategy = .takeTheirs {
        didSet {
            guard chapterStrategy != oldValue else { return }
            chapterDiff = baseChapterDiff.applying(chapterStrategy)
        }
    }

    /// True while the artwork download and tag write are in flight, so the
    /// Apply button cannot be pressed twice.
    public var isApplying = false
    public var applyError: String?

    /// Kept so stepping Back from the tags step restores the whole result list
    /// rather than the one row the user clicked.
    private var lastResults: [MetadataCandidate] = []

    private let downloader: ArtworkDownloader

    public init(
        items: [MediaItem],
        kind: MediaKind = .audiobook,
        downloader: ArtworkDownloader = ArtworkDownloader()
    ) {
        self.selectedItems = items
        self.kind = kind
        self.downloader = downloader
        if let first = items.first {
            self.query = MetadataQuery(from: first.tags, filename: first.url.lastPathComponent)
        }
        rebuildProviders()
    }

    private func rebuildProviders() {
        let previous = provider?.id
        providers = MetadataProviders.serving(kind, region: region)
        provider = providers.first { $0.id == previous } ?? providers.first
    }

    /// Audible has storefronts and OpenLibrary does not, so the region control
    /// only appears where it means something.
    public var showsRegionPicker: Bool { provider is AudibleMetadataProvider }

    public var searchHint: String { provider?.searchHint ?? "Search" }

    /// One book's chapters split across twenty part files would give every part
    /// the whole book's chapter list, so chapters are a single-file operation.
    public var canWriteChapters: Bool { selectedItems.count == 1 }

    public var hasProviderChapters: Bool { !(details?.chapters.isEmpty ?? true) }

    /// The chapters step is skipped entirely when there is nothing to reconcile.
    public var steps: [WizardStep] {
        WizardStep.allCases.filter { $0 != .chapters || (hasProviderChapters && canWriteChapters) }
    }

    public func advance() {
        guard let next = steps.first(where: { $0 > step }) else { return }
        step = next
    }

    public func retreat() {
        guard let previous = steps.last(where: { $0 < step }) else { return }
        step = previous
        applyError = nil
    }

    public var isLastStep: Bool { step == steps.last }

    public func search() async {
        guard !query.isEmpty else {
            searchState = .empty("Type a title, author or ASIN to search.")
            return
        }
        guard let provider else {
            searchState = .error("No metadata provider covers \(kind).")
            return
        }
        searchState = .searching
        do {
            let candidates = try await provider.search(query, limit: 20)
            lastResults = candidates
            searchState = candidates.isEmpty
                ? .empty(emptyHint(for: provider))
                : .results(candidates)
        } catch {
            searchState = .error(error.localizedDescription)
        }
    }

    private func emptyHint(for provider: any MetadataProvider) -> String {
        provider is AudibleMetadataProvider
            ? "Nothing in the \(provider.name) catalogue matched. Try fewer words, another region, or paste the Audible link."
            : "Nothing in \(provider.name) matched. Try fewer words, or the author alone."
    }

    public func select(candidate: MetadataCandidate) async {
        guard let provider else { return }
        self.candidate = candidate
        searchState = .loadingDetails(candidate)
        do {
            let details = try await provider.details(for: candidate)
            self.details = details

            let currentTags = TagSet.common(of: selectedItems.map(\.tags))
            self.tagDiff = TagDiff(current: currentTags, proposed: details.book.tagSet)
            // Everything the provider actually answered, ticked by default.
            self.selectedTagKeys = tagDiff.keys(for: .overwriteAll)

            let mine = selectedItems.count == 1 ? (selectedItems.first?.chapters ?? []) : []
            self.baseChapterDiff = ChapterDiff(current: mine, proposed: details.chapters)
            self.chapterDiff = baseChapterDiff.applying(chapterStrategy)

            self.searchState = lastResults.isEmpty ? .results([candidate]) : .results(lastResults)
            self.step = .tags
        } catch {
            searchState = .error(error.localizedDescription)
        }
    }

    /// Offered in the chapters step's bulk menu. An 85-chapter book is not
    /// retitled by hand, and Audnexus titles are often just "Chapter 1".
    public static let renamePatterns = ["Chapter %n%", "Chapter %n% — %title%", "%n%. %title%", "Part %n%"]

    public func renameChapters(with pattern: String) {
        chapterDiff = chapterDiff.renamingAll(with: pattern)
    }

    public func shiftChapters(by offset: TimeInterval) {
        chapterDiff = chapterDiff.shiftingAll(by: offset)
    }

    /// Throw away the bulk edits and hand-typed titles, back to the strategy.
    public func resetChapters() {
        chapterDiff = baseChapterDiff.applying(chapterStrategy)
    }

    public func apply(_ action: TagDiff.MergeAction) {
        selectedTagKeys = tagDiff.keys(for: action)
    }

    /// Rows that are ticked and actually differ from what the file says — what
    /// the summary counts, rather than every ticked row.
    public var changedTagCount: Int {
        tagDiff.rows.filter { selectedTagKeys.contains($0.key) && $0.isChanged }.count
    }

    public func buildSnapshot() async throws -> (TagSet, [Artwork], [Chapter]?) {
        guard let candidate, let details else { throw MetadataError.emptyQuery }

        let tags = tagDiff.delta(for: selectedTagKeys)

        // Artwork is a nicety; failing to fetch it must not cost the user the
        // tags they just reviewed, so the failure is reported, not thrown.
        var artwork: [Artwork] = []
        if let url = candidate.artworkURL ?? details.book.artworkURL {
            do {
                artwork = [try await downloader.download(from: url)]
            } catch {
                applyError = "Tags applied, but the cover could not be downloaded: \(error.localizedDescription)"
            }
        }

        let chapters = (canWriteChapters && hasProviderChapters) ? chapterDiff.resolved : nil
        return (tags, artwork, chapters)
    }
}
