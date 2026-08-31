import SwiftUI
import MediaCore
import MetadataAPI

public enum SearchLayout: String, CaseIterable, Identifiable {
    case grid = "Grid"
    case list = "List"
    public var id: String { rawValue }
}

public struct AudiobookWizardView: View {
    @State private var model: AudiobookWizardModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("audiobookWizardSearchLayout") private var searchLayout: SearchLayout = .grid
    
    private let applyAction: (TagSet, [Artwork], [Chapter]?) async -> Void
    
    public init(items: [MediaItem], applyAction: @escaping (TagSet, [Artwork], [Chapter]?) async -> Void) {
        _model = State(initialValue: AudiobookWizardModel(items: items))
        self.applyAction = applyAction
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            bottomBar
        }
        .frame(minWidth: 1000, minHeight: 700)
        .onAppear {
            if model.query.searchTerms.isEmpty == false {
                Task { await model.search() }
            }
        }
    }
    
    private var bottomBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            if model.step != .search {
                Button("Back") {
                    switch model.step {
                    case .tags: model.step = .search
                    case .chapters: model.step = .tags
                    case .summary: model.step = .chapters
                    default: break
                    }
                }
                
                if model.step == .summary {
                    Button("Apply Changes") {
                        Task {
                            do {
                                let (tags, artwork, chapters) = try await model.buildSnapshot()
                                await applyAction(tags, artwork, chapters)
                                dismiss()
                            } catch {
                                model.searchState = .error(error.localizedDescription)
                                model.step = .search
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                } else {
                    Button("Next") {
                        switch model.step {
                        case .tags: model.step = .chapters
                        case .chapters: model.step = .summary
                        default: break
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .search: searchStep
        case .tags: tagsStep
        case .chapters: chaptersStep
        case .summary: summaryStep
        }
    }
    
    // MARK: - Step 1: Search
    
    private var searchStep: some View {
        VStack(spacing: 0) {
            // Search Bar Area (Glassy)
            HStack(spacing: 16) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Audiobook (Title, Author, ASIN)", text: Binding(
                        get: { model.query.searchTerms },
                        set: { model.query.keywords = $0; model.query.title = nil; model.query.author = nil }
                    ))
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.search() } }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                Picker("Provider Region", selection: $model.region) {
                    ForEach(AudibleRegion.allCases, id: \.self) { region in
                        Text("Audible \(region.rawValue.uppercased())").tag(region)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                
                Button("Search") { Task { await model.search() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                
                Spacer()
                
                Picker("Layout", selection: $searchLayout) {
                    Image(systemName: "square.grid.2x2").tag(SearchLayout.grid)
                    Image(systemName: "list.bullet").tag(SearchLayout.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
            }
            .padding()
            .glassEffect(.regular)
            
            Divider()
            
            // Results Area
            Group {
                switch model.searchState {
                case .idle:
                    ContentUnavailableView("Search for Audiobooks", systemImage: "books.vertical")
                case .searching:
                    VStack { Spacer(); ProgressView("Searching..."); Spacer() }
                case .loadingDetails(let candidate):
                    VStack { Spacer(); ProgressView("Loading details for \(candidate.title)..."); Spacer() }
                case .results(let candidates):
                    ScrollView {
                        if searchLayout == .grid {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 20)], spacing: 20) {
                                ForEach(candidates) { candidate in
                                    searchGridCard(for: candidate)
                                }
                            }
                            .padding(20)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(candidates) { candidate in
                                    searchListRow(for: candidate)
                                }
                            }
                            .padding(20)
                        }
                    }
                case .error(let message):
                    ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .navigationTitle("Search Audiobooks")
    }
    
    private func searchGridCard(for candidate: AudiobookCandidate) -> some View {
        Button(action: { Task { await model.select(candidate: candidate) } }) {
            VStack(alignment: .leading, spacing: 8) {
                if let url = candidate.artworkURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Rectangle().fill(Color.secondary.opacity(0.1)).aspectRatio(1, contentMode: .fit)
                            .overlay(ProgressView())
                    }
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(candidate.byline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
    
    private func searchListRow(for candidate: AudiobookCandidate) -> some View {
        Button(action: { Task { await model.select(candidate: candidate) } }) {
            HStack(alignment: .center, spacing: 16) {
                if let url = candidate.artworkURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Rectangle().fill(Color.secondary.opacity(0.1))
                    }
                    .frame(width: 80, height: 80)
                    .cornerRadius(6)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.title).font(.title3.bold())
                    if let subtitle = candidate.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(candidate.byline).font(.subheadline)
                    HStack {
                        if let year = candidate.year { Text(String(year)) }
                        if let runtime = candidate.runtimeMinutes { Text("\(runtime / 60)h \(runtime % 60)m") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
    
    // MARK: - Step 2: Tags (Metadata Review)
    
    private func updateProposed(row: TagDiff.Row, newVal: String) -> TagDiff.Row {
        var updatedRow = row
        if let existing = updatedRow.proposed {
            switch existing {
            case .string:
                updatedRow.proposed = .string(newVal)
            case .number:
                if let parsed = Int(newVal) {
                    updatedRow.proposed = .number(parsed)
                } else {
                    updatedRow.proposed = .string(newVal) // fallback if user clears number
                }
            }
        } else {
            updatedRow.proposed = .string(newVal)
        }
        return updatedRow
    }

    private var tagsStep: some View {
        HSplitView {
            // Left Pane: Artwork & Summary
            VStack(spacing: 20) {
                if let candidate = model.candidate, let url = candidate.artworkURL ?? model.details?.book.artworkURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Rectangle().fill(Color.secondary.opacity(0.1)).aspectRatio(1, contentMode: .fit)
                    }
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .frame(maxHeight: 300)
                }
                
                VStack(alignment: .center, spacing: 8) {
                    Text(model.details?.book.title ?? model.candidate?.title ?? "Unknown Title")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    
                    if let authors = model.details?.book.authors, !authors.isEmpty {
                        Text(authors.joined(separator: ", "))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if let summary = model.details?.book.summary {
                    ScrollView {
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal)
                    }
                }
                Spacer()
            }
            .padding()
            .frame(minWidth: 300, idealWidth: 350, maxWidth: 400)
            .background(Color(NSColor.windowBackgroundColor))
            
            // Right Pane: Tags Form
            VStack(spacing: 0) {
                // Column headers
                HStack(spacing: 16) {
                    Text("Tag").frame(width: 90, alignment: .leading)
                    Text("Old").frame(maxWidth: .infinity, alignment: .leading)
                    Text("New (Provider)").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Final (Editable)").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($model.tagDiff.rows) { $row in
                            HStack(spacing: 16) {
                                // 1. Toggle + Tag Name
                                HStack {
                                    Toggle("", isOn: Binding(
                                        get: { model.selectedTagKeys.contains(row.key) },
                                        set: { isOn in
                                            if isOn { model.selectedTagKeys.insert(row.key) } else { model.selectedTagKeys.remove(row.key) }
                                        }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .disabled(row.proposed == nil)
                                    
                                    Text(String(describing: row.key).capitalized)
                                        .font(.caption.bold())
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(width: 90, alignment: .leading)
                                .padding(.leading, 8)
                                
                                // 2. Old (Current File)
                                VStack(alignment: .leading) {
                                    Text(row.current?.stringValue ?? "—")
                                        .foregroundStyle(row.current == nil ? .tertiary : .secondary)
                                        .strikethrough(row.isChanged && model.selectedTagKeys.contains(row.key) && row.current != nil)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                
                                // 3. New (Provider)
                                VStack(alignment: .leading) {
                                    let providerTag = model.details?.book.tagSet[row.key]?.stringValue
                                    Text(providerTag ?? "—")
                                        .foregroundStyle(providerTag == nil ? .tertiary : .primary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                
                                // 4. Final (Editable)
                                VStack(alignment: .leading) {
                                    if row.proposed != nil {
                                        let textBinding = Binding<String>(
                                            get: { row.proposed?.stringValue ?? "" },
                                            set: { newVal in
                                                $row.wrappedValue = updateProposed(row: row, newVal: newVal)
                                            }
                                        )
                                        TextField("Final", text: textBinding)
                                            .textFieldStyle(.plain)
                                        .font(.body)
                                        .foregroundStyle(model.selectedTagKeys.contains(row.key) ? (row.isChanged ? Color.green : Color.primary) : Color.secondary.opacity(0.5))
                                        .padding(8)
                                        .background(Color(NSColor.textBackgroundColor))
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                        )
                                        .disabled(!model.selectedTagKeys.contains(row.key))
                                    } else {
                                        Text("—").foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 8)
                            .padding(.trailing, 16)
                            
                            Divider().padding(.leading, 100)
                        }
                    }
                }
                .background(Color(NSColor.underPageBackgroundColor))
            }
            .background(Color(NSColor.underPageBackgroundColor))
        }
        .navigationTitle("Review Metadata")
    }
    
    // MARK: - Step 3: Chapters
    
    private var chaptersStep: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Chapter Titles")
                    .font(.headline)
                Spacer()
                Picker("Merge Strategy", selection: $model.chapterStrategy) {
                    ForEach(AudiobookWizardModel.ChapterMergeStrategy.allCases) { strategy in
                        Text(strategy.rawValue).tag(strategy)
                    }
                }.pickerStyle(.menu).frame(width: 250)
            }
            .padding()
            .glassEffect(.regular)
            
            Divider()
            
            if model.details?.chapters.isEmpty == true {
                ContentUnavailableView("No Chapters", systemImage: "list.dash", description: Text("This audiobook does not have chapter data available on Audnexus."))
            } else {
                HStack(spacing: 16) {
                    Text("#").frame(width: 40, alignment: .trailing)
                    Text("Old (Current File)").frame(maxWidth: .infinity, alignment: .leading)
                    Text("New (Provider)").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Final (Editable)").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($model.chapterDiff.rows) { $row in
                            HStack(spacing: 16) {
                                Text("\(row.index + 1)")
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 40, alignment: .trailing)
                                
                                // Old (Current File)
                                VStack(alignment: .leading) {
                                    Text(row.current?.title ?? "—")
                                        .foregroundStyle(row.current == nil ? .tertiary : .secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                
                                // New (Provider)
                                VStack(alignment: .leading) {
                                    let providerTitle = model.details.flatMap { $0.chapters.indices.contains(row.index) ? $0.chapters[row.index].title : nil }
                                    Text(providerTitle ?? "—")
                                        .foregroundStyle(providerTitle == nil ? .tertiary : .primary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                
                                // Final (Editable)
                                VStack(alignment: .leading) {
                                    if row.proposed != nil {
                                        TextField("Final Title", text: Binding(
                                            get: { row.proposed?.title ?? "" },
                                            set: { newVal in
                                                var updatedRow = row
                                                updatedRow.proposed?.title = newVal
                                                $row.wrappedValue = updatedRow
                                            }
                                        ))
                                        .textFieldStyle(.plain)
                                        .font(.body)
                                        .foregroundStyle(row.proposed?.title != row.current?.title ? .green : .primary)
                                        .padding(8)
                                        .background(Color(NSColor.textBackgroundColor))
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                        )
                                    } else {
                                        Text("—").foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 8)
                            .padding(.trailing, 16)
                            
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(NSColor.underPageBackgroundColor))
            }
        }
        .navigationTitle("Review Chapters")
    }
    
    // MARK: - Step 4: Summary
    
    private var summaryStep: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.1))
                        .frame(width: 100, height: 100)
                    Image(systemName: "checkmark.seal.fill")
                        .resizable()
                        .frame(width: 60, height: 60)
                        .foregroundStyle(.green)
                }
                
                VStack(spacing: 8) {
                    Text("Ready to Apply")
                        .font(.largeTitle.bold())
                    
                    Text("You are about to update metadata for:")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                    
                    if let candidate = model.candidate {
                        Text(candidate.title)
                            .font(.title2.bold())
                    }
                }
                
                HStack(spacing: 32) {
                    VStack {
                        Text("\(model.selectedTagKeys.count)").font(.title.bold())
                        Text("Tags Modified").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack {
                        Text("\(model.chapterDiff.rows.filter { $0.proposed != nil }.count)").font(.title.bold())
                        Text("Chapters").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(12)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle("Ready to Apply")
    }
}
