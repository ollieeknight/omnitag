import Foundation
import MediaCore
import MetadataAPI
import TagIO

@MainActor @Observable
public final class MetadataWizardModel {
    public enum WizardStep: Int, CaseIterable, Identifiable, Comparable {
        case search = 0
        case episode
        case tags
        case chapters
        case summary

        public var id: Int {
            rawValue
        }

        public var title: String {
            switch self {
            case .search: "Find"
            case .episode: "Episode"
            case .tags: "Tags"
            case .chapters: "Chapters"
            case .summary: "Apply"
            }
        }

        public static func < (a: Self, b: Self) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    public enum EpisodeLoadState {
        case idle
        case loading
        case loaded([TMDBClient.EpisodeSummary])
        case error(String)
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
        didSet {
            if region != oldValue {
                rebuildProviders()
            }
        }
    }

    /// The providers serving this tab, and the one in use. The wizard never
    /// names a service itself — a book tab simply has different providers in it.
    public private(set) var providers: [any MetadataProvider] = []
    public var provider: (any MetadataProvider)?
    /// What the wizard is looking for — settable, because "movie or TV" is a
    /// real choice and not merely which sidebar tab was open. Changing it
    /// throws away everything downstream: the two are different TMDB
    /// endpoints, so results, candidate and episode flow from one are
    /// meaningless under the other.
    public var kind: MediaKind {
        didSet {
            guard kind != oldValue else { return }
            candidate = nil
            details = nil
            isEpisodeFlow = false
            episodeLoadState = .idle
            searchState = .idle
            step = .search
            rebuildProviders()
        }
    }

    /// The kind the files were filed under when the wizard opened, so a
    /// changed choice can be written back on apply.
    private let originalKind: MediaKind

    /// Movie and TV are the one pair a user genuinely picks between — an
    /// audiobook is never a film. Shown only where the choice is real.
    public var offersKindChoice: Bool {
        [.movie, .tvEpisode].contains(originalKind)
    }

    /// The kind to reclassify the selection to on apply, or `nil` when the
    /// files already agree with the choice. A file must not leave the wizard
    /// tagged as one kind while the library files it as another.
    public var reclassifiedKind: MediaKind? {
        guard offersKindChoice else { return nil }
        return selectedItems.contains { $0.kind != kind } ? kind : nil
    }

    public var query = MetadataQuery()
    public var selectedItems: [MediaItem]

    public var candidate: MetadataCandidate?
    public var details: MetadataDetails?

    /// True for the life of a TV candidate's flow, whether or not an episode
    /// has been picked yet — this is what keeps `.episode` addressable by
    /// `retreat()` even after picking one. A prior version cleared this the
    /// moment an episode was chosen, which made `.episode` vanish from
    /// `steps` entirely: pressing Back from the Tags step then skipped past
    /// the episode list straight to Search, silently losing the show and the
    /// picked episode both. See `docs/MOVIES_TV.md`.
    public private(set) var isEpisodeFlow = false
    /// The episode step's `.task(id: selectedSeason)` is the only thing that
    /// fetches a season — a `didSet` here as well meant selecting a show while
    /// a non-default season was showing fired two races for one list.
    public var selectedSeason = 1

    /// The episode number the file's own name points at, if any — the picker
    /// marks that row so a season of 22 does not have to be read to find it.
    public var suggestedEpisode: Int? {
        query.episode
    }

    public var episodeLoadState: EpisodeLoadState = .idle

    public var tagDiff = TagDiff(current: TagSet(), proposed: TagSet(), kind: .audiobook)
    public var selectedTagKeys: Set<TagKey> = []

    /// The alignment as it came out of the provider, kept so "Reset" can throw
    /// away the bulk edits and hand-typed titles without another round trip.
    private var baseChapterDiff = ChapterDiff(current: [], proposed: [])
    public var chapterDiff = ChapterDiff(current: [], proposed: [])
    public var selectedChapterIDs: Set<ChapterDiff.Row.ID> = []
    public var skipChapters = false

    /// What the chapters step should say about this pairing, if anything —
    /// worked out once, when the candidate is chosen.
    public private(set) var chapterNotice: String?
    public var cleanOverwrite = false {
        didSet {
            guard cleanOverwrite != oldValue else { return }
            if cleanOverwrite {
                selectedTagKeys.formUnion(tagDiff.rows.filter { $0.current != nil }.map(\.key))
            } else {
                selectedTagKeys.subtract(tagDiff.rows.filter { $0.proposed == nil }.map(\.key))
            }
        }
    }

    public var clearingTagKeys: Set<TagKey> {
        guard cleanOverwrite else { return [] }
        return Set(tagDiff.rows.filter { row in
            row.current != nil && row.proposed == nil && selectedTagKeys.contains(row.key)
        }.map(\.key))
    }

    /// True while the artwork download and tag write are in flight, so the
    /// Apply button cannot be pressed twice.
    public var isApplying = false
    public var applyError: String?

    /// Move the ticked titles a row down or up.
    ///
    /// Only the titles move. The times belong to the audio, not to the provider,
    /// so a list that came back one row out is fixed by sliding the words along.
    public func shiftProposedTitles(by offset: Int) {
        guard offset != 0, !selectedChapterIDs.isEmpty else { return }
        var titles = chapterDiff.rows.map { $0.proposed?.title }
        for index in offset > 0 ? selectedChapterIDs.sorted().reversed() : selectedChapterIDs.sorted() {
            let destination = index + offset
            guard titles.indices.contains(index), titles.indices.contains(destination) else { continue }
            titles.swapAt(index, destination)
        }
        for index in chapterDiff.rows.indices {
            chapterDiff.rows[index].proposed?.title = titles[index] ?? ""
        }
        selectedChapterIDs = Set(selectedChapterIDs.compactMap { index in
            titles.indices.contains(index + offset) ? index + offset : nil
        })
    }

    /// Kept so stepping Back from the tags step restores the whole result list
    /// rather than the one row the user clicked.
    private var lastResults: [MetadataCandidate] = []

    private let downloader: ArtworkDownloader

    public init(
        items: [MediaItem],
        kind: MediaKind = .audiobook,
        downloader: ArtworkDownloader = ArtworkDownloader()
    ) {
        selectedItems = items
        self.kind = kind
        originalKind = kind
        self.downloader = downloader
        if let first = items.first {
            query = MetadataQuery(from: first.tags, filename: first.url.lastPathComponent)
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
    public var showsRegionPicker: Bool {
        provider is AudibleMetadataProvider
    }

    public var searchHint: String {
        provider?.searchHint ?? "Search"
    }

    /// What the empty search step says before anything is typed. The audiobook
    /// wording ("paste an Audible link") is meaningless on a movie or TV tab.
    public var searchPrompt: String {
        provider is AudibleMetadataProvider
            ? "The query was built from the file's own tags and name. Edit it above, or paste an Audible link."
            : "The query was built from the file's own tags and name. Edit it above and press Return."
    }

    /// True when the chosen provider needs a key it has not been given —
    /// worth saying before a search is typed and fails, not after.
    public var needsAPIKey: Bool {
        provider?.isMissingAPIKey ?? false
    }

    /// One book's chapters split across twenty part files would give every part
    /// the whole book's chapter list, so chapters are a single-file operation.
    public var canWriteChapters: Bool {
        selectedItems.count == 1
    }

    /// One episode's season/episode number/title applied to every file in a
    /// multi-file selection would be silently wrong for every file but one —
    /// the same reasoning as `canWriteChapters`.
    public var canPickEpisode: Bool {
        selectedItems.count == 1
    }

    /// Fields that identify one *track*, not the release it belongs to.
    ///
    /// A music selection is usually a whole album, and the wizard applies one
    /// result to everything selected — so writing these would stamp one song's
    /// title and number onto every file. Same reasoning as `canWriteChapters`
    /// and `canPickEpisode`, and the same single-file condition.
    public static let perTrackKeys: Set<TagKey> = [.title, .trackNumber, .trackTotal, .discNumber, .discTotal]

    /// True when the result names one track but more than one file would
    /// receive it, so the per-track fields have to be withheld.
    public var withholdsPerTrackFields: Bool {
        kind == .music && selectedItems.count > 1
    }

    public var hasProviderChapters: Bool {
        !(details?.chapters.isEmpty ?? true)
    }

    /// The single question the Apply button, the summary tile and the snapshot
    /// all ask: are chapters part of this write?
    public var willWriteChapters: Bool {
        hasProviderChapters && canWriteChapters && !skipChapters
    }

    /// True only when every selected file could actually receive artwork —
    /// e.g. a PDF cover is a page-one render, never stored art.
    public var canWriteArtwork: Bool {
        !selectedItems.isEmpty && selectedItems.allSatisfy { MediaTagReader.canWriteArtwork($0.container) }
    }

    /// There is a cover to offer, but at least one selected file cannot
    /// store it — worth telling the user before Apply, not after.
    public var hasUnwritableArtwork: Bool {
        (candidate?.artworkURL ?? details?.book.artworkURL) != nil && !canWriteArtwork
    }

    /// The chapters step is skipped when there is nothing to reconcile; the
    /// episode step stays in the wizard for as long as a TV candidate is
    /// active, picked episode or not, so Back can always return to it rather
    /// than skipping straight to Search.
    public var steps: [WizardStep] {
        WizardStep.allCases.filter {
            ($0 != .chapters || (hasProviderChapters && canWriteChapters))
                && ($0 != .episode || isEpisodeFlow)
        }
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

    public var isLastStep: Bool {
        step == steps.last
    }

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
            let candidates = try await query.ranked(provider.search(query, kind: kind, limit: 20))
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
            let details = try await provider.details(for: candidate, kind: kind)

            // A TV search candidate names a show, not an episode — see
            // `docs/MOVIES_TV.md`. Land on the episode picker instead of
            // building a tag diff against show-level data nobody asked to write.
            // Skipped for a multi-file selection: one episode's number and
            // title cannot apply to more than one file, so the show-level
            // fields (showName, year, genre) are offered instead — the same
            // choice `canWriteChapters` makes for chapters.
            if kind == .tvEpisode, provider.hasEpisodePicker, canPickEpisode {
                self.details = details
                isEpisodeFlow = true
                searchState = lastResults.isEmpty ? .results([candidate]) : .results(lastResults)
                step = .episode
                // Open on the season the filename named, falling back to 1,
                // and `.idle` so a second show never shows the first one's
                // episodes. The episode step's `.task(id: selectedSeason)`
                // does the fetch.
                selectedSeason = query.season ?? 1
                episodeLoadState = .idle
                loadedSeason = nil
                return
            }

            // A fresh non-TV candidate (or a TV candidate too many files to
            // pick an episode for) never carries a stale episode flow from a
            // previous search in this same wizard session.
            isEpisodeFlow = false
            applyDetails(details, candidate: candidate)
            searchState = lastResults.isEmpty ? .results([candidate]) : .results(lastResults)
            step = .tags
        } catch {
            searchState = .error(error.localizedDescription)
        }
    }

    /// What `episodeLoadState` currently holds, so stepping Back into the
    /// episode step does not refetch a list already on screen.
    private var loadedSeason: (showID: String, season: Int)?

    /// The episode step's list, refetched whenever `selectedSeason` changes.
    public func loadSeasonEpisodes() async {
        guard let tmdb = provider as? TMDBProvider, let showID = candidate?.id else { return }
        if let loadedSeason, loadedSeason == (showID, selectedSeason) {
            return
        }
        episodeLoadState = .loading
        do {
            let episodes = try await tmdb.seasonEpisodes(showID: showID, season: selectedSeason)
            loadedSeason = (showID, selectedSeason)
            episodeLoadState = .loaded(episodes)
        } catch {
            loadedSeason = nil
            episodeLoadState = .error(error.localizedDescription)
        }
    }

    /// Resolves the show + season/episode into the same shape every other
    /// kind reaches `.tags` with, then advances exactly as `select` does.
    public func selectEpisode(_ episode: TMDBClient.EpisodeSummary) async {
        guard let tmdb = provider as? TMDBProvider, let candidate, let showID = self.candidate?.id else { return }
        searchState = .loadingDetails(candidate)
        do {
            let details = try await tmdb.episodeDetails(
                showID: showID, showName: candidate.title, season: selectedSeason, episode: episode.number
            )
            applyDetails(details, candidate: candidate)
            searchState = lastResults.isEmpty ? .results([candidate]) : .results(lastResults)
            step = .tags
        } catch {
            searchState = .error(error.localizedDescription)
        }
    }

    /// The tag-diff and chapter-diff build shared by a resolved movie/book/
    /// audiobook candidate and a resolved TV episode.
    private func applyDetails(_ details: MetadataDetails, candidate: MetadataCandidate) {
        var details = details
        if details.book.series == nil && candidate.series != nil {
            details.book.series = candidate.series
            details.book.seriesIndex = candidate.seriesIndex
        }
        if details.book.publisher == nil && candidate.publisher != nil {
            details.book.publisher = candidate.publisher
        }
        self.details = details

        let currentTags = TagSet.common(of: selectedItems.map(\.tags))
        var proposed = details.book.tagSet
        if withholdsPerTrackFields {
            // Removed rather than left unticked: a row the user could tick
            // would put one song's title back onto the whole album.
            for key in Self.perTrackKeys {
                proposed[key] = nil
            }
        }
        tagDiff = TagDiff(current: currentTags, proposed: proposed, kind: kind)
        cleanOverwrite = true
        // In clean overwrite, all proposed keys are written and unprovided current keys are cleared:
        selectedTagKeys = Set(tagDiff.rows.filter { $0.proposed != nil || $0.current != nil }.map(\.key))

        let mine = selectedItems.count == 1 ? (selectedItems.first?.chapters ?? []) : []
        baseChapterDiff = ChapterDiff(current: mine, proposed: details.chapters).aligned()
        chapterDiff = baseChapterDiff
        (skipChapters, chapterNotice) = Self.chapterDefault(file: mine, provider: details.chapters)
    }

    /// Offered in the chapters step's bulk menu. An 85-chapter book is not
    /// retitled by hand, and Audnexus titles are often just "Chapter 1".
    public static let renamePatterns = ["Chapter %n%", "Chapter %n% — %title%", "%n%. %title%", "Part %n%"]

    public func renameChapters(with pattern: String) {
        chapterDiff = chapterDiff.renamingAll(with: pattern)
    }

    /// Throw away the bulk edits and hand-typed titles.
    public func resetChapters() {
        chapterDiff = baseChapterDiff
    }

    /// Whether to start with chapters skipped, and what to tell the user.
    ///
    /// The file's timings are always kept, so a differing chapter count is worth
    /// a note, not a refusal. Real titles the provider cannot match are the one
    /// case where doing nothing is the better default.
    static func chapterDefault(file: [Chapter], provider: [Chapter]) -> (skip: Bool, notice: String?) {
        guard !provider.isEmpty else { return (false, nil) }

        // Protecting titles that cannot be recovered comes first.
        let protection = ChapterDiff.protectionNotice(file: file, provider: provider)
        if protection.skip {
            return protection
        }

        if file.count >= 2, file.count != provider.count {
            // Say what the alignment actually achieved, not just that the
            // counts differ: "titles are matched by timestamp" is a promise,
            // and the user deserves to know how much of it was kept.
            let matched = ChapterDiff.matchedCount(fileChapters: file, providerChapters: provider)
            let unmatched = file.count - matched
            var notice = "The file has \(file.count) chapters and the provider \(provider.count). "
                + "Your timings are kept; \(matched) matched by timestamp"
            notice += unmatched == 0
                ? "."
                : ", and ^[\(unmatched) chapter](inflect: true) kept its current title."
            return (false, notice)
        }
        return (false, nil)
    }

    public func apply(_ action: TagDiff.MergeAction) {
        switch action {
        case .merge:
            cleanOverwrite = false
            selectedTagKeys = tagDiff.keys(for: .merge)
        case .overwriteAll:
            cleanOverwrite = true
            selectedTagKeys = Set(tagDiff.rows.filter { $0.proposed != nil || $0.current != nil }.map(\.key))
        case .none:
            cleanOverwrite = false
            selectedTagKeys = []
        }
    }

    /// Rows that are ticked and actually differ from what the file says (updates + removals).
    public var changedTagCount: Int {
        let updated = tagDiff.rows.filter { row in
            row.proposed != nil && selectedTagKeys.contains(row.key) && row.isChanged
        }.count
        let cleared = clearingTagKeys.count
        return updated + cleared
    }

    public func buildSnapshot() async throws -> (TagSet, [Artwork], [Chapter]?, Set<TagKey>) {
        guard let candidate, let details else { throw MetadataError.emptyQuery }

        let tags = tagDiff.delta(for: selectedTagKeys)
        let clearing = clearingTagKeys

        // Artwork is a nicety; failing to fetch it must not cost the user the
        // tags they just reviewed, so the failure is reported, not thrown.
        // mkv has no artwork writer yet, so downloading one there would be a
        // wasted round trip for a cover that can never be stored.
        var artwork: [Artwork] = []
        if canWriteArtwork, let url = candidate.artworkURL ?? details.book.artworkURL {
            do {
                artwork = try await [downloader.download(from: url)]
            } catch {
                applyError = "Tags applied, but the cover could not be downloaded: \(error.localizedDescription)"
            }
        }

        let chapters = willWriteChapters ? chapterDiff.resolved : nil
        return (tags, artwork, chapters, clearing)
    }
}
