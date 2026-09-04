import EditEngine
import MediaCore
import SwiftUI

/// Find & replace and the text transforms, over the current selection.
///
/// One sheet rather than two: they are the same shape — pick a field, pick an
/// operation, see what it would do, apply as one undoable batch. Splitting
/// them would mean two menu items for one mental step.
struct BulkEditSheet: View {
    let items: [MediaItem]
    let apply: (TagEdit) async -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Operation: String, CaseIterable, Identifiable {
        case replace = "Find & Replace"
        case transform = "Transform"
        case copy = "Copy Field"
        case swap = "Swap Fields"

        var id: String {
            rawValue
        }
    }

    @State private var operation: Operation = .replace
    @State private var field: TagKey = .title
    @State private var otherField: TagKey = .album
    @State private var transform: TextTransform = .titleCase
    @State private var find = ""
    @State private var replacement = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Action", selection: $operation) {
                    ForEach(Operation.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Section {
                    fieldPicker("Field", selection: $field)

                    switch operation {
                    case .replace:
                        TextField("Find", text: $find)
                        TextField("Replace with", text: $replacement)
                    case .transform:
                        Picker("Transform", selection: $transform) {
                            ForEach(TextTransform.allCases) { Text($0.rawValue).tag($0) }
                        }
                    case .copy:
                        fieldPicker("Copy to", selection: $otherField)
                    case .swap:
                        fieldPicker("Swap with", selection: $otherField)
                    }
                }

                Section("Preview") {
                    preview
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 520, height: 460)
    }

    private func fieldPicker(_ label: String, selection: Binding<TagKey>) -> some View {
        Picker(label, selection: selection) {
            ForEach(fields, id: \.self) { key in
                Text(TagKey.label(for: key)).tag(key)
            }
        }
    }

    /// Every field any selected file could carry, so a mixed selection can
    /// still be edited on the fields its kinds share.
    private var fields: [TagKey] {
        var seen: [TagKey] = []
        for kind in Set(items.map(\.kind)).sorted(by: { "\($0)" < "\($1)" }) {
            for (key, _) in TagKey.standardFields(for: kind) where !seen.contains(key) {
                seen.append(key)
            }
        }
        return seen
    }

    private var edit: TagEdit {
        switch operation {
        case .replace: .replace(field, find: find, with: replacement)
        case .transform: .transform(field, transform)
        case .copy: .copyField(from: field, to: otherField)
        case .swap: .swapFields(field, otherField)
        }
    }

    /// What each file's affected fields become. Only rows that actually change
    /// are listed — a preview showing fifty unchanged rows hides the four that
    /// matter.
    private var changes: [(name: String, before: String, after: String)] {
        items.compactMap { item in
            let after = edit.previewed(on: item.tags)
            let keys: [TagKey] = operation == .copy || operation == .swap ? [field, otherField] : [field]
            let before = keys.map { item.tags[$0]?.stringValue ?? "" }.joined(separator: "  ·  ")
            let result = keys.map { after[$0]?.stringValue ?? "" }.joined(separator: "  ·  ")
            guard before != result else { return nil }
            return (item.url.lastPathComponent, before, result)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if isIncomplete {
            Text("Fill in the fields above to see what would change.")
                .foregroundStyle(.secondary)
        } else if changes.isEmpty {
            Label("Nothing would change in \(items.count == 1 ? "this file" : "these \(items.count) files").",
                  systemImage: "equal.circle")
                .foregroundStyle(.secondary)
        } else {
            ForEach(changes.prefix(50), id: \.name) { change in
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(change.before.isEmpty ? "—" : change.before)
                            .foregroundStyle(.secondary)
                            .strikethrough()
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(change.after.isEmpty ? "—" : change.after)
                    }
                    .lineLimit(1)
                }
            }
            if changes.count > 50 {
                Text("…and ^[\(changes.count - 50) more file](inflect: true).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isIncomplete: Bool {
        operation == .replace && find.isEmpty
    }

    private var footer: some View {
        HStack {
            if !isIncomplete, !changes.isEmpty {
                Text("^[\(changes.count) file](inflect: true) will change")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                let edit = edit
                Task {
                    await apply(edit)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isIncomplete || changes.isEmpty)
        }
        .padding()
        .background(.bar)
    }
}
