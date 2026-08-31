import Foundation
import MediaCore
import MetadataAPI

@MainActor @Observable
public final class AudiobookWizardModel {
    public enum WizardStep: Int, CaseIterable, Identifiable {
        case search = 0
        case tags
        case chapters
        case summary
        
        public var id: Int { rawValue }
    }

    public enum SearchState {
        case idle
        case searching
        case results([AudiobookCandidate])
        case loadingDetails(AudiobookCandidate)
        case error(String)
    }

    public enum ChapterMergeStrategy: String, CaseIterable, Identifiable {
        case keepMine = "Keep mine, add extras"
        case takeTheirs = "Take theirs completely"
        case keepTitlesTakeTimes = "Keep my titles, take their times"
        
        public var id: String { rawValue }
    }

    public var step: WizardStep = .search
    public var searchState: SearchState = .idle
    public var region: AudibleRegion = .unitedKingdom
    
    public var query = AudiobookQuery()
    public var selectedItems: [MediaItem]
    
    public var candidate: AudiobookCandidate?
    public var details: AudiobookDetails?
    
    public var tagDiff = TagDiff(current: TagSet(), proposed: TagSet())
    public var chapterDiff = ChapterDiff(current: [], proposed: [])
    
    private let downloader: ArtworkDownloader
    
    public var selectedTagKeys: Set<TagKey> = []
    public var chapterStrategy: ChapterMergeStrategy = .takeTheirs

    public init(
        items: [MediaItem], 
        downloader: ArtworkDownloader = ArtworkDownloader()
    ) {
        self.selectedItems = items
        self.downloader = downloader
        if let first = items.first {
            self.query = AudiobookQuery(from: first.tags, filename: first.url.lastPathComponent)
        }
    }
    
    private var service: AudiobookMetadataService {
        AudiobookMetadataService(region: region)
    }
    
    public func search() async {
        searchState = .searching
        do {
            let candidates = try await service.search(query, limit: 20)
            if candidates.isEmpty {
                searchState = .error("No results found.")
            } else {
                searchState = .results(candidates)
            }
        } catch {
            searchState = .error(error.localizedDescription)
        }
    }
    
    public func select(candidate: AudiobookCandidate) async {
        self.candidate = candidate
        searchState = .loadingDetails(candidate)
        do {
            let details = try await service.details(for: candidate.asin)
            self.details = details
            
            let currentTags = TagSet.common(of: selectedItems.map(\.tags))
            self.tagDiff = TagDiff(current: currentTags, proposed: details.book.tagSet)
            // Default to selecting all keys that have a proposed value.
            self.selectedTagKeys = Set(self.tagDiff.rows.filter { $0.proposed != nil }.map(\.key))
            
            let maxChapters = selectedItems.max(by: { $0.chapters.count < $1.chapters.count })?.chapters ?? []
            self.chapterDiff = ChapterDiff(current: maxChapters, proposed: details.chapters)
            
            self.step = .tags
        } catch {
            searchState = .error(error.localizedDescription)
        }
    }

    public func buildSnapshot() async throws -> (TagSet, [Artwork], [Chapter]?) {
        guard let candidate = candidate, let details = details else {
            throw MetadataError.emptyQuery
        }
        
        let currentTags = TagSet.common(of: selectedItems.map(\.tags))
        let finalTags = tagDiff.overwriting(selectedTagKeys, into: currentTags)
        
        var artwork: [Artwork] = []
        if let url = candidate.artworkURL ?? details.book.artworkURL {
            let downloaded = try await downloader.download(from: url)
            artwork = [downloaded]
        }
        
        var chapters: [Chapter]? = nil
        if !details.chapters.isEmpty {
            switch chapterStrategy {
            case .keepMine:
                chapters = chapterDiff.keepMine()
            case .takeTheirs:
                chapters = chapterDiff.takeTheirs()
            case .keepTitlesTakeTimes:
                chapters = chapterDiff.keepTitlesTakeTimes()
            }
        }
        
        return (finalTags, artwork, chapters)
    }
}
