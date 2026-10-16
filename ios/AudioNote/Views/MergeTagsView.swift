import SwiftUI

/// Picks the tags to fold into `target`. Presented from a long-press on a
/// library tag chip (spec §4).
///
/// Two stages: pick, then confirm. The confirmation is not decoration —
/// there is no undo (spec §Decision), so it is the only thing standing
/// between a mistyped merge and a whole-library rewrite. It therefore names
/// the target, names every tag that disappears with its count, and states
/// how many records are affected. A merge aimed the wrong way is only
/// visible if you can see which way is which, so this is a screen rather
/// than an `alert`: a `confirmationDialog` cannot carry a detail list, and
/// an `alert`'s message is too small to hold one.
struct MergeTagsView: View {
    let target: String
    @ObservedObject var viewModel: TranscriptionViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var selection: Set<String> = []
    @State private var isConfirming = false
    @State private var isMerging = false

    /// Every tag except the target's own identity, filtered by the search
    /// box, most-used first.
    ///
    /// Counts come from `tagCount(for:)` rather than a fresh tally so the
    /// number here cannot disagree with the number on the chip the user just
    /// pressed. Ordering falls back to the name for a stable result —
    /// otherwise tags with equal counts would reshuffle between openings.
    private var candidates: [String] {
        let targetKey = TagIdentity.key(target)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.availableTags
            .filter { TagIdentity.key($0) != targetKey }
            .filter { needle.isEmpty || TagIdentity.key($0).contains(needle) }
            .sorted { lhs, rhs in
                let l = viewModel.tagCount(for: lhs)
                let r = viewModel.tagCount(for: rhs)
                if l != r { return l > r }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    /// Distinct records the merge would rewrite. **Not** the sum of the
    /// per-tag counts: one record carrying two of the ticked tags is
    /// rewritten once, and adding its count twice would overstate the blast
    /// radius on the one page that exists to make the blast radius clear.
    private var affectedRecordCount: Int {
        let keys = Set(selection.map(TagIdentity.key))
        return viewModel.historyRecords.filter { record in
            record.tags?.contains { keys.contains(TagIdentity.key($0.name)) } == true
        }.count
    }

    private var sortedSelection: [String] {
        selection.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if isConfirming {
                    confirmation
                } else {
                    picker
                }
            }
            .navigationTitle(
                String(format: "Library.MergeTags.Title".localized, target)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Action.Cancel".localized) { dismiss() }
                }
            }
        }
    }

    // MARK: - Stage 1: pick

    private var picker: some View {
        List {
            ForEach(candidates, id: \.self) { tag in
                Button {
                    toggle(tag)
                } label: {
                    HStack {
                        Text(tag)
                        Spacer()
                        Text("\(viewModel.tagCount(for: tag))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if isTicked(tag) {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Library.MergeTags.Search".localized)
        .safeAreaInset(edge: .bottom) {
            Button {
                isConfirming = true
            } label: {
                Text(String(format: "Library.MergeTags.Footer".localized, selection.count, target))
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(.regularMaterial)
        }
    }

    // MARK: - Stage 2: confirm

    private var confirmation: some View {
        List {
            Section {
                Text(String(
                    format: "Library.MergeTags.Confirm.Title".localized,
                    affectedRecordCount
                ))
                .font(.headline)
            } header: {
                Text(target)
            }

            Section {
                ForEach(sortedSelection, id: \.self) { tag in
                    HStack {
                        Text(tag)
                        Spacer()
                        Text("\(viewModel.tagCount(for: tag))")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Library.MergeTags.Confirm.Merging".localized)
            } footer: {
                Text("Library.MergeTags.Confirm.Body".localized)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Same position as the picker stage's footer, so the path from
            // "I chose tags" to "I am about to rewrite my library" is one
            // continuous gesture rather than a jump between toolbars.
            Button {
                performMerge()
            } label: {
                Text("Library.MergeTags.Confirm.Button".localized)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isMerging)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(.regularMaterial)
        }
    }

    // MARK: - Actions

    private func performMerge() {
        let sources = Array(selection)
        isMerging = true
        Task {
            await viewModel.mergeTag(target, from: sources)
            isMerging = false
            dismiss()
        }
    }

    /// Compared by identity, so ticking `Work` when `work` is already ticked
    /// replaces it rather than storing two spellings of one intent.
    private func isTicked(_ tag: String) -> Bool {
        selection.contains { TagIdentity.key($0) == TagIdentity.key(tag) }
    }

    private func toggle(_ tag: String) {
        if let existing = selection.first(where: { TagIdentity.key($0) == TagIdentity.key(tag) }) {
            selection.remove(existing)
        } else {
            selection.insert(tag)
        }
    }
}

/// `.sheet(item:)` needs an `Identifiable`, and `String` is not one. Wrapping
/// rather than switching to `isPresented` plus a separate string binding keeps
/// the sheet's own lifetime tied to the value it was opened with.
struct MergeTagTarget: Identifiable {
    let name: String
    var id: String { name }
}
