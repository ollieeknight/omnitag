import MediaCore
import SwiftUI
import TagIO

/// Inspection surfaces: the tags OmniTag does not model, and whether an
/// audiobook's chapter marks land where the audio actually breaks. Split out
/// of `App.swift` because they are their own concern, and because
/// `LibraryModel` had outgrown one file.
extension LibraryModel {
    /// One unmanaged tag: a frame or atom OmniTag does not model, kept so a
    /// round-trip never destroys it (`DECISIONS.md`'s lossless invariant).
    struct CustomTag: Identifiable, Hashable {
        let name: String
        let value: String

        var id: String {
            name
        }

        /// Audible m4b files carry a multi-kilobyte base64 blob. It has to
        /// round-trip whole, but showing it raw would bury the inspector.
        var displayValue: String {
            isTruncated ? String(value.prefix(120)) + "…" : value
        }

        var isTruncated: Bool {
            value.count > 120
        }
    }

    /// The unmanaged tags the whole selection shares. Sorted by name so the
    /// list does not reorder itself between reads.
    var customTags: [CustomTag] {
        commonTags.values
            .compactMap { key, value in
                guard case let .custom(name) = key, let text = value.stringValue else { return nil }
                return CustomTag(name: name, value: text)
            }
            .sorted { $0.name < $1.name }
    }

    func setCustomTag(_ name: String, to value: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty else { return }
        await edit(.set(.custom(trimmed), .string(value)))
    }

    func removeCustomTag(_ name: String) async {
        await edit(.clear(.custom(name)))
    }

    /// Only for a single audio file with more than one chapter: the check
    /// measures a waveform, and an epub's table of contents has none.
    var canCheckBoundaries: Bool {
        guard selectedItems.count == 1, let item = selectedItems.first else { return false }
        return item.chapters.count > 1 && item.container.isAVPlayerPlayable
    }

    /// Where a mark should move, given what the check found. `nil` when
    /// there is nothing to correct.
    ///
    /// Two cases, and they move in opposite directions: a mark sitting inside
    /// a pause moves **back** to where the audio stopped, and a mark caught
    /// mid-sentence moves to the nearest pause, whichever side that is.
    static func shift(for result: ChapterBoundaryCheck.Result) -> TimeInterval? {
        if result.isMidSentence {
            return result.nearestPause
        }
        // Half a second of lead-in is below what anyone notices.
        guard let before = result.silenceBefore, before > 0.5 else { return nil }
        return -before
    }

    /// The chapter list with one mark moved. Pure, so the preview and the
    /// write cannot disagree.
    static func nudged(_ chapters: [Chapter], using result: ChapterBoundaryCheck.Result) -> [Chapter] {
        guard let shift = shift(for: result),
              let position = chapters.firstIndex(where: { $0.index == result.index })
        else { return chapters }

        var moved = chapters
        // Never past the previous mark: a chapter that starts before the one
        // before it is worse than one that starts a second late.
        let floor = position > 0 ? moved[position - 1].start + 1 : 0
        moved[position].start = max(floor, moved[position].start + shift)
        return moved
    }

    func nudgeChapter(_ result: ChapterBoundaryCheck.Result) async {
        guard let item = selectedItems.first else { return }
        await applyChapters(Self.nudged(item.chapters, using: result))
        await checkChapterBoundaries()
    }

    func boundaryResult(forChapter index: Int) -> ChapterBoundaryCheck.Result? {
        boundaryResults.first { $0.index == index }
    }

    func checkChapterBoundaries() async {
        guard let item = selectedItems.first, canCheckBoundaries else { return }
        isCheckingBoundaries = true
        defer { isCheckingBoundaries = false }
        boundaryResults = await (try? ChapterBoundaryCheck.check(item.chapters, in: item.url)) ?? []
    }
}
