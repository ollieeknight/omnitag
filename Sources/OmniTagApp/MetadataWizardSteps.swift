import MediaCore
import MetadataAPI
import SwiftUI

/// The chapters and summary steps, split out of `MetadataWizardView`
/// only because SwiftLint caps how much one type may span.
extension MetadataWizardView {
    // MARK: - Step 3: Chapters

    var chaptersStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Update chapters", isOn: Binding(
                    get: { !model.skipChapters },
                    set: { model.skipChapters = !$0 }
                ))
                .toggleStyle(.switch)
                .help("Off leaves the file's chapters exactly as they are")

                Menu {
                    Section("Rename every chapter") {
                        ForEach(MetadataWizardModel.renamePatterns, id: \.self) { pattern in
                            Button(pattern) { model.renameChapters(with: pattern) }
                        }
                    }
                    Divider()
                    Button("Reset to the provider's titles") { model.resetChapters() }
                } label: {
                    Label("Bulk Tools", systemImage: "wand.and.rays")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.skipChapters)
                .help("Retitle all \(model.chapterDiff.rows.count) chapters at once")

                Divider().frame(height: 16)

                Button { model.shiftProposedTitles(by: -1) } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(model.selectedChapterIDs.isEmpty || model.skipChapters)
                .help("Move the selected titles up a row")

                Button { model.shiftProposedTitles(by: 1) } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(model.selectedChapterIDs.isEmpty || model.skipChapters)
                .help("Move the selected titles down a row")

                Spacer()

                Text(model.skipChapters
                    ? "Chapters untouched"
                    : "^[\(model.chapterDiff.resolved.count) chapter](inflect: true) will be written")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .glassEffect(.regular)

            if let notice = model.chapterNotice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }

            Divider()

            HStack(spacing: 12) {
                Text("#").frame(width: 36, alignment: .trailing)
                Text("Start").frame(width: 80, alignment: .leading)
                Text("Currently").frame(maxWidth: .infinity, alignment: .leading)
                Text("New Title").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            List(selection: $model.selectedChapterIDs) {
                ForEach($model.chapterDiff.rows) { $row in
                    chapterRow($row)
                        .tag(row.id)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)

                    Divider().padding(.leading, 16)
                }
            }
            .listStyle(.plain)
            .background(Color(NSColor.underPageBackgroundColor))
        }
    }

    @ViewBuilder
    private func chapterRow(_ row: Binding<ChapterDiff.Row>) -> some View {
        let changed = row.wrappedValue.proposed?.title != row.wrappedValue.current?.title

        HStack(spacing: 12) {
            Text("\(row.wrappedValue.index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)

            Text(row.wrappedValue.proposed.map { LibraryView.formatted($0.start) } ?? "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(row.wrappedValue.current?.title ?? "—")
                .foregroundStyle(row.wrappedValue.current == nil ? .tertiary : .secondary)
                .strikethrough(changed && row.wrappedValue.current != nil)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if row.wrappedValue.proposed != nil {
                TextField("Title", text: Binding(
                    get: { row.wrappedValue.proposed?.title ?? "" },
                    set: { row.wrappedValue.proposed?.title = $0 }
                ))
                .textFieldStyle(.plain)
                .padding(6)
                .contentShape(.rect(cornerRadius: 6))
                .background(Color(NSColor.textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Title for chapter \(row.wrappedValue.index + 1)")
            } else {
                Text("Dropped")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(changed ? Color.accentColor.opacity(0.06) : .clear)
    }

    // MARK: - Step 4: Summary

    var summaryStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                cover(model.candidate?.artworkURL ?? model.details?.book.artworkURL)
                    .frame(maxWidth: 180)

                VStack(spacing: 6) {
                    Text(model.candidate?.title ?? "Ready to Apply")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Edits stay in memory until you press Save, and Undo takes them all back in one step.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 0) {
                    summaryTile("\(model.changedTagCount)", "Fields changed")
                    Divider().frame(height: 40)
                    summaryTile(
                        model.willWriteChapters ? "\(model.chapterDiff.resolved.count)" : "—",
                        "Chapters"
                    )
                    Divider().frame(height: 40)
                    summaryTile("\(model.selectedItems.count)", "Files")
                }
                .padding(.vertical, 12)
                .frame(maxWidth: 460)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6), in: .rect(cornerRadius: 12))

                if model.skipChapters {
                    Label(
                        "Chapters are skipped: existing file chapters will remain untouched.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                } else if model.hasProviderChapters, !model.canWriteChapters {
                    Label(
                        "Chapters are skipped: \(model.selectedItems.count) files are selected, and one book's chapter list does not belong in every part.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                }

                if let kind = model.reclassifiedKind {
                    Label(
                        "^[\(model.selectedItems.count) file](inflect: true) will also be filed under \(LibraryScope.kind(kind).title).",
                        systemImage: "arrow.right.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                }

                if model.withholdsPerTrackFields {
                    Label(
                        "Track title and number are skipped: \(model.selectedItems.count) files are selected, and one song's title and number cannot be right for all of them. Album, artist, year, genre and artwork still apply.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                }

                if model.hasUnwritableArtwork {
                    Label(
                        // mkv grew an artwork writer in the seventh pass; what
                        // is left without one is epub-without-a-cover and pdf.
                        "Cover art is skipped: this format cannot store a cover, so the artwork will not be saved.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                }

                if model.cleanOverwrite, !model.clearingTagKeys.isEmpty {
                    Label(
                        "Clean overwrite: \(model.clearingTagKeys.count) unprovided tags will be removed from file.",
                        systemImage: "sparkles"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.selectedItems.prefix(6), id: \.url) { item in
                        Text(item.url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if model.selectedItems.count > 6 {
                        Text("and \(model.selectedItems.count - 6) more…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func summaryTile(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title.bold().monospacedDigit())
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
