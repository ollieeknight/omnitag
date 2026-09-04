import EditEngine
import MediaCore
import SwiftUI
import TagIO
import UniformTypeIdentifiers

struct InspectorView: View {
    @Bindable var model: LibraryModel
    @State private var isArtworkTargeted = false
    @State private var showingNewCustomTag = false
    @State private var newCustomName = ""
    @State private var newCustomValue = ""

    var body: some View {
        Form {
            if model.selection.isEmpty {
                emptyInspector
            } else {
                if !readOnlySelection.isEmpty {
                    Label(
                        "\(readOnlySelection.count) selected file\(readOnlySelection.count == 1 ? " has" : "s have") no writer yet — edits cannot be saved.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }

                kindSection

                artworkSection

                Section(header: Text(header)) {
                    ForEach(fields, id: \.key) { field in
                        TagField(key: field.key, label: field.label, model: model)
                    }
                }

                chapterSection

                subtitleTrackSection

                customTagSection
            }
        }
        .formStyle(.grouped)
    }

    private var emptyInspector: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: model.scope.symbol)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            // "Music" is a mass noun, so inflecting the tab's own title gave
            // "5 musics". Each scope names its unit instead.
            Text(model.visible.isEmpty
                ? "No \(model.scope.title)"
                : "^[\(model.visible.count) \(model.scope.singular)](inflect: true)")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Select files in the list to edit tags, cover art, and chapters.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Media Kind

    private var kindSection: some View {
        Section {
            // `nil` is a real state, not a missing one: a mixed selection has
            // no single kind, and the picker has to say so rather than show
            // one file's kind as if it spoke for the rest.
            Picker("Kind", selection: Binding<MediaKind?>(
                get: { model.selectedKind },
                set: { newKind in
                    guard let newKind else { return }
                    Task { await model.setKind(newKind) }
                }
            )) {
                if model.selectedKind == nil {
                    Text("Multiple").tag(MediaKind?.none)
                }
                ForEach(MediaKind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(MediaKind?.some(kind))
                }
            }
            // Only makes sense for one file at a time — a multi-selection's
            // items were classified independently and may have different
            // reasons, so no single caption could speak for all of them.
            if let item = model.selectedItems.first, model.selectedItems.count == 1,
               let reason = LibraryModel.kindGuessReason(url: item.url) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Artwork

    /// The cover is the one tag people judge a library by, so it gets a well
    /// rather than a text field: drop an image on it, or use the menu.
    private var artworkSection: some View {
        Section(model.kind == .book && !canEditArtwork ? "Preview" : "Cover") {
            VStack(spacing: 10) {
                artworkWell
                if !canEditArtwork {
                    Text(artworkExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Menu("Set…") {
                        Button("Choose File…") { model.pickArtwork() }
                        Button("Find in Folder") { Task { await model.findLocalArtwork() } }
                        Button("Paste from Clipboard") { Task { await model.pasteArtwork() } }
                    }
                    .disabled(!canEditArtwork)

                    if commonArtwork != nil, canEditArtwork {
                        Button("Remove", role: .destructive) { Task { await model.setArtwork([]) } }
                    }
                    Spacer()
                    if let artwork = commonArtwork {
                        Text("\(artwork.mimeType.replacingOccurrences(of: "image/", with: "").uppercased()) · \(byteCount(artwork.data.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var artworkWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.35))
            if let data = commonArtwork?.data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: 10))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: mixedArtwork ? "photo.on.rectangle.angled" : "photo")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text(mixedArtwork ? "Multiple covers" : (canEditArtwork ? "Drop image or ⌘V" : "No cover"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isArtworkTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isArtworkTargeted ? 3 : 1, dash: commonArtwork == nil ? [6] : [])
                )
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard canEditArtwork, let first = urls.first else { return false }
            Task { await model.setArtwork(fromFile: first) }
            return true
        } isTargeted: { isArtworkTargeted = $0 && canEditArtwork }
        .animation(.easeOut(duration: 0.15), value: isArtworkTargeted)
        .contextMenu {
            if canEditArtwork {
                Button("Paste Cover") { Task { await model.pasteArtwork() } }
                Button("Find in Folder") { Task { await model.findLocalArtwork() } }
                Button("Choose File…") { model.pickArtwork() }
                if commonArtwork != nil {
                    Divider()
                    Button("Remove Cover", role: .destructive) { Task { await model.setArtwork([]) } }
                }
            }
        }
        .accessibilityLabel(commonArtwork == nil ? "No cover. Drop an image to set one." : "Cover art")
    }

    /// Whether every selected file can actually take a new cover.
    private var canEditArtwork: Bool {
        !model.selectedItems.isEmpty
            && model.selectedItems.allSatisfy { MediaTagReader.canWriteArtwork($0.container) }
    }

    private var artworkExplanation: String {
        if model.selectedItems.contains(where: { $0.container == .pdf }) {
            return "This is page one, rendered. A PDF has nowhere to store a cover."
        }
        if model.selectedItems.contains(where: { $0.container == .epub }) {
            return "This EPUB has no cover image to replace — adding one would mean rewriting its manifest."
        }
        return "The selected format has no writable artwork yet."
    }

    /// The cover the whole selection agrees on, if any.
    private var commonArtwork: Artwork? {
        let covers = model.selectedItems.map(\.artwork.first)
        guard let first = covers.first, covers.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private var mixedArtwork: Bool {
        model.selectedItems.count > 1 && model.selectedItems.contains { !$0.artwork.isEmpty }
    }

    private func byteCount(_ bytes: Int) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    // MARK: - Chapters

    /// One file only: chapters belong to a single recording, and the transport
    /// bar's "Add Marker" needs somewhere to show what it just added.
    @ViewBuilder
    private var chapterSection: some View {
        if let item = singleSelection, !item.chapters.isEmpty {
            let editable = MediaTagReader.canWriteChapters(item.container)
            Section("^[\(item.chapters.count) chapter](inflect: true)") {
                ForEach(Array(item.chapters.enumerated()), id: \.offset) { offset, chapter in
                    HStack(spacing: 8) {
                        Button(LibraryView.formatted(chapter.start)) {
                            model.player.load(url: item.url)
                            model.player.seek(to: chapter.start)
                        }
                        .buttonStyle(.link)
                        .font(.callout.monospacedDigit())
                        .help("Play from here")

                        if editable {
                            ChapterTitleField(index: offset, title: chapter.title, model: model)
                        } else {
                            Text(chapter.title)
                        }

                        if editable {
                            Button {
                                Task { await model.removeChapter(at: offset) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove this chapter")
                            .accessibilityLabel("Remove chapter \(offset + 1)")
                        }
                    }

                    if let result = model.boundaryResult(forChapter: chapter.index) {
                        boundaryRow(result, editable: editable)
                    }
                }
                if !editable {
                    Text("This format's chapters are read-only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.canCheckBoundaries {
                    boundaryCheckControl
                }
            }
        }
    }

    /// What the audio looks like around one mark. A sentence, never a
    /// pass/fail badge: a correct mark can sit on a spoken chapter
    /// announcement, so `AUDIOBOOKS.md` says report the shape and let the
    /// user judge. Only `isMidSentence` is treated as a fault.
    private func boundaryRow(_ result: ChapterBoundaryCheck.Result, editable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: result.isMidSentence ? "exclamationmark.triangle.fill" : "waveform")
                .foregroundStyle(result.isMidSentence ? .orange : .secondary)
                .font(.caption)

            Text(result.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if editable, let shift = LibraryModel.shift(for: result) {
                Button(String(format: "Move %+.1fs", shift)) {
                    Task { await model.nudgeChapter(result) }
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Move this mark to where the audio actually breaks")
            }
        }
        .padding(.leading, 4)
    }

    /// Checking decodes a window of audio per chapter, so it is asked for
    /// rather than run on every selection.
    private var boundaryCheckControl: some View {
        HStack(spacing: 8) {
            if model.isCheckingBoundaries {
                ProgressView().controlSize(.small)
                Text("Checking chapter marks…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(model.boundaryResults.isEmpty ? "Check Chapter Marks" : "Check Again") {
                    Task { await model.checkChapterBoundaries() }
                }
                .controlSize(.small)
                if !model.boundaryResults.isEmpty {
                    let faults = model.boundaryResults.count(where: \.isMidSentence)
                    Text(faults == 0
                        ? "No marks land mid-sentence."
                        : "^[\(faults) mark](inflect: true) land mid-sentence.")
                        .font(.caption)
                        .foregroundStyle(faults == 0 ? Color.secondary : Color.orange)
                }
            }
        }
        .help("Measures whether each mark sits where the audio actually breaks")
    }

    // MARK: - Custom tags

    /// The tags OmniTag does not model, which round-trip as `TagKey.custom`.
    ///
    /// The lossless invariant promises they survive; without this the user
    /// has no way to confirm that, and no way to correct a wrong one. Kept
    /// below the modelled fields because it is an inspection surface, not the
    /// everyday one.
    @ViewBuilder
    private var customTagSection: some View {
        let tags = model.customTags
        if !tags.isEmpty || showingNewCustomTag {
            Section("^[\(tags.count) other tag](inflect: true)") {
                ForEach(tags) { tag in
                    CustomTagRow(tag: tag, model: model)
                }

                if showingNewCustomTag {
                    HStack(spacing: 6) {
                        TextField("NAME", text: $newCustomName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        TextField("Value", text: $newCustomValue)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            Task {
                                await model.setCustomTag(newCustomName, to: newCustomValue)
                                newCustomName = ""
                                newCustomValue = ""
                                showingNewCustomTag = false
                            }
                        }
                        .disabled(newCustomName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { showingNewCustomTag = false }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                } else {
                    Button("Add Tag…") { showingNewCustomTag = true }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Subtitle Tracks

    /// One file only, same reasoning as chapters: a track's identity belongs
    /// to one specific file. mkv only — `canWriteSubtitleTracks` is false for
    /// every other container, so this never shows an uneditable list, it
    /// just doesn't appear.
    @ViewBuilder
    private var subtitleTrackSection: some View {
        if let item = singleSelection, !item.subtitleTracks.isEmpty,
           MediaTagReader.canWriteSubtitleTracks(item.container) {
            Section("^[\(item.subtitleTracks.count) subtitle track](inflect: true)") {
                ForEach(item.subtitleTracks) { track in
                    SubtitleTrackRow(track: track, model: model)
                }
            }
        }
    }

    /// Files the user can edit on screen but not save: mkv, flac today.
    private var readOnlySelection: [MediaItem] {
        model.selectedItems.filter { !MediaTagReader.canWrite($0.container) }
    }

    private var singleSelection: MediaItem? {
        model.selectedItems.count == 1 ? model.selectedItems.first : nil
    }

    private var header: String {
        guard model.selection.count != 1 else {
            return singleSelection?.url.lastPathComponent ?? ""
        }
        // Naming the kind saves reading the rows to find out what these are,
        // and it is exactly what the field list below is keyed to.
        let count = model.selection.count
        guard let kind = model.selectedKind else {
            return "\(count) files selected"
        }
        return "^[\(count) \(LibraryScope.kind(kind).singular)](inflect: true) selected"
    }

    /// Field set per media type — same UX, different vocabulary. One table,
    /// shared with the wizard's tag diff, so the two cannot drift apart.
    private var fields: [(key: TagKey, label: String)] {
        TagKey.standardFields(for: model.kind)
    }
}

/// One tag field bound to the whole selection. Commits on Return or focus loss,
/// never per keystroke — a keystroke-level undo stack would be useless for batches.
private struct TagField: View {
    let key: TagKey
    let label: String
    @Bindable var model: LibraryModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var shared: String? {
        model.commonTags[key]?.stringValue
    }

    private var isMixed: Bool {
        shared == nil && model.selection.count > 1
    }

    var body: some View {
        TextField(label, text: $text, prompt: Text(isMixed ? "Multiple values" : label), axis: axis)
            .lineLimit(key == .synopsis ? 2 ... 8 : 1 ... 1)
            // A borderless field in a grouped Form is only as wide as its
            // text, so short values like "1" or "2024" had a hit target a few
            // pixels across. The bordered style gives the whole control frame
            // to hit-testing.
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    commit()
                }
            }
            .onChange(of: shared, initial: true) { _, value in
                if !focused {
                    text = value ?? ""
                }
            }
            .onChange(of: model.selection) { _, _ in text = shared ?? "" }
    }

    private var axis: Axis {
        key == .synopsis ? .vertical : .horizontal
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // `shared` is nil for a mixed selection, so comparing against `?? ""`
        // read an emptied field as "unchanged" and made mixed tags impossible
        // to clear. Mixed means every value differs, so any commit is a change.
        guard isMixed || trimmed != (shared ?? "") else { return }
        Task {
            await model.edit(trimmed.isEmpty ? .clear(key) : .set(key, value(from: trimmed)))
        }
    }

    private func value(from string: String) -> TagValue {
        if let number = Int(string), MPEG4NumericKeys.contains(key) {
            return .number(number)
        }
        return .string(string)
    }
}

/// One chapter title. Commits on Return or focus loss for the same reason
/// `TagField` does: a keystroke-level undo stack is no use to anyone.
private struct ChapterTitleField: View {
    let index: Int
    let title: String
    @Bindable var model: LibraryModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Title", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    commit()
                }
            }
            .onChange(of: title, initial: true) { _, value in
                if !focused {
                    text = value
                }
            }
            .accessibilityLabel("Title for chapter \(index + 1)")
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != title else { return }
        Task { await model.renameChapter(at: index, to: trimmed) }
    }
}

/// One subtitle track's editable metadata: language, name, and the three
/// player-facing flags. No add/remove — that means muxing, out of scope here.
private struct SubtitleTrackRow: View {
    let track: SubtitleTrack
    @Bindable var model: LibraryModel
    @State private var language = ""
    @State private var name = ""
    @FocusState private var focusedField: Field?

    private enum Field { case language, name }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(track.codecID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                TextField("Language (e.g. eng)", text: $language)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .language)
                    .onSubmit(commitLanguage)
                    .onChange(of: focusedField) { old, new in
                        if old == .language, new != .language {
                            commitLanguage()
                        }
                    }
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .onSubmit(commitName)
                    .onChange(of: focusedField) { old, new in
                        if old == .name, new != .name {
                            commitName()
                        }
                    }
            }
            HStack(spacing: 16) {
                Toggle("Default", isOn: Binding(get: { track.isDefault }, set: { setFlag(isDefault: $0) }))
                Toggle("Forced", isOn: Binding(get: { track.isForced }, set: { setFlag(isForced: $0) }))
                Toggle("Enabled", isOn: Binding(get: { track.isEnabled }, set: { setFlag(isEnabled: $0) }))
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        .onChange(of: track, initial: true) { _, value in
            if focusedField != .language {
                language = value.language ?? ""
            }
            if focusedField != .name {
                name = value.name ?? ""
            }
        }
    }

    private func commitLanguage() {
        var updated = track
        updated.language = language.trimmingCharacters(in: .whitespaces).isEmpty ? nil : language
        guard updated != track else { return }
        Task { await model.updateSubtitleTrack(updated) }
    }

    private func commitName() {
        var updated = track
        updated.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        guard updated != track else { return }
        Task { await model.updateSubtitleTrack(updated) }
    }

    private func setFlag(isDefault: Bool? = nil, isForced: Bool? = nil, isEnabled: Bool? = nil) {
        var updated = track
        if let isDefault {
            updated.isDefault = isDefault
        }
        if let isForced {
            updated.isForced = isForced
        }
        if let isEnabled {
            updated.isEnabled = isEnabled
        }
        Task { await model.updateSubtitleTrack(updated) }
    }
}

/// Keys the file formats store as integers. Kept next to the field that needs
/// it rather than exported from TagIO — the UI is the only caller.
private let MPEG4NumericKeys: Set<TagKey> = [
    .year, .trackNumber, .trackTotal, .discNumber, .discTotal,
    .seriesIndex, .seasonNumber, .episodeNumber
]

extension MediaKind {
    var title: String {
        switch self {
        case .music: "Music"
        case .audiobook: "Audiobooks"
        case .book: "Books"
        case .movie: "Movies"
        case .tvEpisode: "TV Shows"
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .audiobook: "headphones"
        case .book: "book"
        case .movie: "film"
        case .tvEpisode: "tv"
        }
    }
}

/// One unmanaged tag. Its value commits on Return or focus loss, like every
/// other field in the inspector, and a long value (an Audible JSON blob) is
/// shown truncated with the whole thing behind a tooltip.
private struct CustomTagRow: View {
    let tag: LibraryModel.CustomTag
    @Bindable var model: LibraryModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(tag.name)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
                .help(tag.name)

            if tag.isTruncated {
                // Not editable: a 5 000-character blob in a text field is a
                // way to destroy it by accident, not a way to edit it.
                Text(tag.displayValue)
                    .font(.callout)
                    .lineLimit(1)
                    .help("\(tag.value.count) characters — too long to edit here, and preserved as-is")
            } else {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused {
                            commit()
                        }
                    }
            }

            Button {
                Task { await model.removeCustomTag(tag.name) }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this tag")
            .accessibilityLabel("Remove \(tag.name)")
        }
        .onAppear { text = tag.value }
        .onChange(of: tag.value) { _, value in
            if !focused {
                text = value
            }
        }
    }

    private func commit() {
        guard text != tag.value else { return }
        Task { await model.setCustomTag(tag.name, to: text) }
    }
}
