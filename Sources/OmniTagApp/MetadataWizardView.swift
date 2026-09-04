import MediaCore
import MetadataAPI
import SwiftUI

public enum SearchLayout: String, CaseIterable, Identifiable {
    case grid = "Grid"
    case list = "List"
    public var id: String {
        rawValue
    }
}

public struct MetadataWizardView: View {
    // Not `private`: the chapters and summary steps live in
    // MetadataWizardSteps.swift, and `private` is file-scoped.
    @State var model: MetadataWizardModel
    @Environment(\.dismiss) var dismiss
    @AppStorage("audiobookWizardSearchLayout") private var searchLayout: SearchLayout = .grid

    private let applyAction: (TagSet, [Artwork], [Chapter]?, Set<TagKey>, MediaKind?) async -> Void

    public init(
        items: [MediaItem], kind: MediaKind = .audiobook,
        applyAction: @escaping (TagSet, [Artwork], [Chapter]?, Set<TagKey>, MediaKind?) async -> Void
    ) {
        _model = State(initialValue: MetadataWizardModel(items: items, kind: kind))
        self.applyAction = applyAction
    }

    public var body: some View {
        VStack(spacing: 0) {
            stepBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 620, idealHeight: 760)
        .onAppear {
            if !model.query.isEmpty {
                Task { await model.search() }
            }
        }
    }

    // MARK: - Chrome

    /// Four steps, one of which disappears when the provider has no chapters —
    /// so the bar is built from `model.steps`, never the full enum.
    private var stepBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.steps.enumerated()), id: \.element.id) { offset, step in
                if offset > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Label {
                    Text(step.title)
                } icon: {
                    Image(systemName: step < model.step ? "checkmark.circle.fill" : "\(offset + 1).circle")
                }
                .font(.callout.weight(step == model.step ? .semibold : .regular))
                .foregroundStyle(stepColour(step))
                .accessibilityLabel("Step \(offset + 1) of \(model.steps.count): \(step.title)")
                .accessibilityAddTraits(step == model.step ? [.isSelected] : [])
            }
            Spacer()
            if let title = model.candidate?.title, model.step != .search {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func stepColour(_ step: MetadataWizardModel.WizardStep) -> HierarchicalShapeStyle {
        step == model.step ? .primary : (step < model.step ? .secondary : .tertiary)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            if let applyError = model.applyError {
                Label(applyError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isStaticText)
            }

            Spacer()

            if model.step != .search {
                Button("Back") { model.retreat() }
                    .disabled(model.isApplying)

                if model.step == .episode {
                    // Advancing happens by picking an episode from the list,
                    // not a Next button — there is nothing to advance with yet.
                } else if model.isLastStep {
                    Button {
                        Task { await applyAndDismiss() }
                    } label: {
                        if model.isApplying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Apply to \(fileCountLabel)")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(model.isApplying || (model.changedTagCount == 0 && !model.willWriteChapters))
                } else {
                    Button("Next") { model.advance() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private var fileCountLabel: String {
        model.selectedItems.count == 1 ? "1 File" : "\(model.selectedItems.count) Files"
    }

    private func applyAndDismiss() async {
        model.isApplying = true
        model.applyError = nil
        defer { model.isApplying = false }
        do {
            let (tags, artwork, chapters, clearing) = try await model.buildSnapshot()
            await applyAction(tags, artwork, chapters, clearing, model.reclassifiedKind)
            dismiss()
        } catch {
            // Stay on the summary: the user's review is worth more than the sheet.
            model.applyError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .search: searchStep
        case .episode: episodeStep
        case .tags: tagsStep
        case .chapters: chaptersStep
        case .summary: summaryStep
        }
    }

    // MARK: - Step 1: Search

    private var searchStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Movie or TV is a real choice, not merely whichever sidebar
                // tab happened to be open. Changing it re-runs the search:
                // TMDB serves the two from different endpoints, so results
                // from one mean nothing under the other.
                if model.offersKindChoice {
                    Picker("Looking for", selection: $model.kind) {
                        Text("Movie").tag(MediaKind.movie)
                        Text("TV").tag(MediaKind.tvEpisode)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: model.kind) {
                        guard !model.query.isEmpty else { return }
                        Task { await model.search() }
                    }
                    .help("Which catalogue to search. Applying a result also files the file under this kind.")
                }

                HStack(spacing: 6) {
                    Image(systemName: model.query.asin == nil ? "magnifyingglass" : "barcode.viewfinder")
                        .foregroundStyle(model.query.asin == nil ? .secondary : Color.accentColor)
                    TextField(model.searchHint, text: $model.query.searchText)
                        .textFieldStyle(.plain)
                        // Claim the empty space in the faux search box, so a
                        // click to the right of the text focuses the field
                        // instead of landing on the container behind it.
                        .frame(maxWidth: .infinity)
                        .onSubmit { Task { await model.search() } }
                        .accessibilityLabel("Search \(model.provider?.name ?? "for metadata")")
                    if model.query.asin != nil {
                        Text("ASIN")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: .capsule)
                            .help("Looked up directly — the catalogue has books its keyword index cannot reach")
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor), in: .rect(cornerRadius: 8))

                if model.providers.count > 1 {
                    Picker("Provider", selection: Binding(
                        get: { model.provider?.id ?? "" },
                        set: { id in model.provider = model.providers.first { $0.id == id } }
                    )) {
                        ForEach(model.providers, id: \.id) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                if model.showsRegionPicker {
                    Picker("Region", selection: $model.region) {
                        ForEach(AudibleRegion.allCases, id: \.self) { region in
                            Text(region.rawValue.uppercased()).tag(region)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                    .help("Storefronts are not mirrors — a book missing from one may be in another")
                    .onChange(of: model.region) { _, _ in
                        if case .results = model.searchState {
                            Task { await model.search() }
                        }
                    }
                }

                Button("Search") { Task { await model.search() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)

                Picker("Layout", selection: $searchLayout) {
                    Image(systemName: "square.grid.2x2").tag(SearchLayout.grid)
                        .accessibilityLabel("Grid")
                    Image(systemName: "list.bullet").tag(SearchLayout.list)
                        .accessibilityLabel("List")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 90)
            }
            .padding(12)
            .glassEffect(.regular)

            Divider()

            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
        }
    }

    @ViewBuilder
    private var results: some View {
        switch model.searchState {
        case .idle:
            if model.needsAPIKey {
                ContentUnavailableView {
                    Label("\(model.provider?.name ?? "This provider") Needs a Key", systemImage: "key")
                } description: {
                    Text("Searching \(model.provider?.name ?? "this provider") needs a free API key. Add one in Preferences, then come back.")
                } actions: {
                    SettingsLink { Text("Open Preferences…") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    "Search \(model.provider?.name ?? "for Metadata")",
                    systemImage: model.provider?.hasEpisodePicker == true ? "film" : "books.vertical",
                    description: Text(model.searchPrompt)
                )
            }
        case .searching:
            ProgressView("Searching \(model.provider?.name ?? "")…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loadingDetails(candidate):
            ProgressView("Fetching chapters for \(candidate.title)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .empty(hint):
            ContentUnavailableView {
                Label("No Matches", systemImage: "magnifyingglass")
            } description: {
                Text(hint)
            } actions: {
                Button("Search Again") { Task { await model.search() } }
            }
        case let .error(message):
            ContentUnavailableView {
                Label(model.needsAPIKey ? "No API Key" : "Search Failed", systemImage: model.needsAPIKey ? "key" : "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                // Retrying a search that failed for want of a key just fails
                // again; the only useful action is the one that fixes it.
                if model.needsAPIKey {
                    SettingsLink { Text("Open Preferences…") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Try Again") { Task { await model.search() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        case let .results(candidates):
            ScrollView {
                if searchLayout == .grid {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 20)],
                        spacing: 20
                    ) {
                        ForEach(candidates) { searchGridCard(for: $0) }
                    }
                    .padding(20)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(candidates) { searchListRow(for: $0) }
                    }
                    .padding(20)
                }
            }
        }
    }

    /// A square placeholder keeps the grid from reflowing as covers arrive.
    func cover(_ url: URL?, size: CGFloat? = nil) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        .accessibilityHidden(true)
    }

    private func searchGridCard(for candidate: MetadataCandidate) -> some View {
        Button {
            Task { await model.select(candidate: candidate) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover(candidate.artworkURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !candidate.byline.isEmpty {
                        Text(candidate.byline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let year = candidate.year {
                        Text(verbatim: "\(year)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: candidate))
    }

    private func searchListRow(for candidate: MetadataCandidate) -> some View {
        Button {
            Task { await model.select(candidate: candidate) }
        } label: {
            HStack(spacing: 16) {
                cover(candidate.artworkURL, size: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title).font(.headline)
                    if let subtitle = candidate.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !candidate.byline.isEmpty {
                        Text(candidate.byline).font(.subheadline)
                    }
                    Text(detailLine(for: candidate))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: candidate))
    }

    /// TMDB search results carry no director/cast, so `byline` is often empty
    /// for movies and TV — "Title by" would read wrong to VoiceOver.
    private func accessibilityLabel(for candidate: MetadataCandidate) -> String {
        candidate.byline.isEmpty ? candidate.title : "\(candidate.title) by \(candidate.byline)"
    }

    /// Year, runtime and identifier on one line — built as a string rather than
    /// a stack of conditional views, which the type checker cannot chew through.
    private func detailLine(for candidate: MetadataCandidate) -> String {
        var parts: [String] = []
        if let year = candidate.year {
            parts.append(String(year))
        }
        if let runtime = candidate.runtimeMinutes {
            parts.append("\(runtime / 60)h \(runtime % 60)m")
        }
        if let identifier = candidate.displayID {
            parts.append(identifier)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Step: Episode (TV only)

    /// A TV search result names a show; this picks the season and episode
    /// before there is anything to diff. See `docs/MOVIES_TV.md`.
    private var episodeStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(model.candidate?.title ?? "")
                    .font(.headline)
                Spacer()
                Stepper(value: $model.selectedSeason, in: 0 ... 50) {
                    Text("Season \(model.selectedSeason)")
                }
                .frame(width: 160)
            }
            .padding(12)
            .glassEffect(.regular)

            Divider()

            episodeResults
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
        }
        // The one place a season is fetched: on appearing, on every season
        // change, and on stepping Back into this view.
        .task(id: model.selectedSeason) {
            await model.loadSeasonEpisodes()
        }
    }

    @ViewBuilder
    private var episodeResults: some View {
        switch model.episodeLoadState {
        case .idle:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView("Loading season \(model.selectedSeason)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .error(message):
            ContentUnavailableView {
                Label("Could Not Load Episodes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.loadSeasonEpisodes() } }
                    .buttonStyle(.borderedProminent)
            }
        case let .loaded(episodes):
            if episodes.isEmpty {
                ContentUnavailableView("No Episodes", systemImage: "tv", description: Text("Season \(model.selectedSeason) has no episodes listed."))
            } else {
                List(episodes) { episode in
                    let suggested = episode.number == model.suggestedEpisode
                    Button {
                        Task { await model.selectEpisode(episode) }
                    } label: {
                        HStack {
                            Text("\(episode.number).")
                                .foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .trailing)
                            Text(episode.title)
                                .fontWeight(suggested ? .semibold : .regular)
                            if suggested {
                                Text("From filename")
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: .capsule)
                            }
                            Spacer()
                            if let airDate = episode.airDate {
                                Text(airDate).font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(suggested ? "Matches the season and episode in this file's name" : "")
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Step 2: Tags

    private var tagsStep: some View {
        HSplitView {
            bookSummaryPane
            tagTable
        }
    }

    private var bookSummaryPane: some View {
        ScrollView {
            VStack(spacing: 16) {
                cover(model.candidate?.artworkURL ?? model.details?.book.artworkURL)
                    .frame(maxWidth: 260)

                VStack(spacing: 6) {
                    Text(model.details?.book.title ?? model.candidate?.title ?? "Unknown Title")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    if let byline = model.details?.book.byline, !byline.isEmpty {
                        Text(byline)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                if let summary = model.details?.book.summary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var tagTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("^[\(model.changedTagCount) field](inflect: true) will change")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                ForEach(TagDiff.MergeAction.allCases) { action in
                    Button(action.rawValue) { model.apply(action) }
                        .help(helpText(for: action))
                }
                Divider().frame(height: 16)
                Toggle("Clean overwrite", isOn: $model.cleanOverwrite)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help("Remove existing tags on the file that are not provided by the metadata source")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 12) {
                Text("Field").frame(width: 130, alignment: .leading)
                Text("Currently").frame(maxWidth: .infinity, alignment: .leading)
                Text("New Value").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($model.tagDiff.rows) { $row in
                        tagRow($row)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(NSColor.underPageBackgroundColor))
        }
        .frame(minWidth: 460)
    }

    private func helpText(for action: TagDiff.MergeAction) -> String {
        switch action {
        case .merge: "Tick only the fields this file does not already have."
        case .overwriteAll: "Tick every field the provider supplied."
        case .none: "Untick everything and choose by hand."
        }
    }

    @ViewBuilder
    private func tagRow(_ row: Binding<TagDiff.Row>) -> some View {
        let key = row.wrappedValue.key
        let isOn = model.selectedTagKeys.contains(key)
        let providerValue = model.details?.book.tagSet[key]?.stringValue
        let isClearing = model.cleanOverwrite && row.wrappedValue.proposed == nil && row.wrappedValue.current != nil

        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { isOn },
                set: { on in
                    if on {
                        model.selectedTagKeys.insert(key)
                    } else {
                        model.selectedTagKeys.remove(key)
                    }
                }
            )) {
                Text(label(for: key))
                    .font(.callout)
                    .foregroundStyle(isOn ? (isClearing ? .red : .primary) : .secondary)
                    .lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .frame(width: 130, alignment: .leading)
            .accessibilityLabel(isClearing ? "Remove \(label(for: key))" : "Write \(label(for: key))")

            Text(row.wrappedValue.current?.stringValue ?? "—")
                .foregroundStyle(row.wrappedValue.current == nil ? .tertiary : .secondary)
                .strikethrough(isOn && (row.wrappedValue.isChanged || isClearing) && row.wrappedValue.current != nil)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isClearing, isOn {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                    Text("Will be removed")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    TextField("New value", text: Binding(
                        get: { row.wrappedValue.proposed?.stringValue ?? "" },
                        set: {
                            row.wrappedValue = retyped(row.wrappedValue, to: $0)
                            model.selectedTagKeys.insert(key)
                        }
                    ), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1 ... 4)
                        .padding(6)
                        // The padding belongs to the modified view, not the
                        // plain field, so without this the click target was
                        // only the glyphs. Typing into an unticked empty row
                        // now ticks it, rather than being ignored outright.
                        .contentShape(.rect(cornerRadius: 6))
                        .background(Color(NSColor.textBackgroundColor), in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        .foregroundStyle(isOn ? .primary : .tertiary)
                        .accessibilityLabel("New \(label(for: key))")

                    if let providerValue, providerValue != row.wrappedValue.proposed?.stringValue {
                        Button {
                            row.wrappedValue.proposed = model.details?.book.tagSet[key]
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Restore the provider's value")
                        .accessibilityLabel("Restore the provider's \(label(for: key))")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isOn && (row.wrappedValue.isChanged || isClearing) ? Color.accentColor.opacity(0.06) : .clear)
    }

    /// Keeps a numeric tag numeric while the user types, and falls back to a
    /// string the moment it stops being a number — the format writers accept both.
    private func retyped(_ row: TagDiff.Row, to text: String) -> TagDiff.Row {
        var updated = row
        if case .number = row.proposed, let parsed = Int(text) {
            updated.proposed = .number(parsed)
        } else {
            updated.proposed = .string(text)
        }
        return updated
    }

    private func label(for key: TagKey) -> String {
        TagKey.label(for: key)
    }
}
