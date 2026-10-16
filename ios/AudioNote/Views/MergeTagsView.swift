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
    /// box, in pinyin/alphabetical order.
    ///
    /// **Not** the chip row's order. `availableTags` sorts by max score
    /// desc — a *discovery* ranking for a horizontal strip, where the point
    /// is that the most important tags float into view. This screen is a
    /// *lookup* surface: the job is "find the misspelling, tick it". What
    /// makes a grid findable is a position you can predict, and a score
    /// ranking has none — you would read every cell to decide whether to
    /// stop. In a single column count-desc could still work (scan down,
    /// stop when it gets small); once the cells sit side by side it cannot.
    ///
    /// `localizedStandardCompare` rather than `localizedCaseInsensitiveCompare`
    /// so Chinese collates by pinyin, English ignores case, and `Apple2`
    /// precedes `Apple10`.
    ///
    /// Counts still come from `tagCount(for:)` rather than a fresh tally, so
    /// the number on a tile cannot disagree with the number on the chip the
    /// user just pressed.
    private var candidates: [String] {
        let targetKey = TagIdentity.key(target)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.availableTags
            .filter { TagIdentity.key($0) != targetKey }
            .filter { needle.isEmpty || TagIdentity.key($0).contains(needle) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
        ScrollView {
            // Content-sized tiles that wrap, not a fixed-column grid: tag
            // names vary by an order of magnitude, and `GridItem` divides the
            // width equally, so equal columns would leave most of every row
            // empty. See `FlowRow` for what this costs (no laziness) and
            // why it is worth paying here.
            FlowRow(spacing: 8, lineSpacing: 8) {
                ForEach(candidates, id: \.self) { tag in
                    candidateTile(tag)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if candidates.isEmpty {
                Text("Library.MergeTags.Empty".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
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

    /// Reads as the chip it replaces — same radius, same accent-when-on —
    /// but sized to its own text instead of a column's share of the width.
    ///
    /// **No `maxWidth: .infinity` here.** `FlowRow` measures subviews with
    /// `.unsspecified`; a greedy tile reports infinity, gets its own line,
    /// and silently turns the flow back into one-per-row. `minWidth` is the
    /// floor, not a share.
    ///
    /// The accent fill is load-bearing, not decoration. The original single
    /// column marked a selection with a trailing ✓, which worked only
    /// because every row put it in the same place at the right edge; among
    /// ragged neighbours a corner checkmark is too weak to scan. Multi-select
    /// is the whole point of this screen, so what has to be legible at a
    /// glance is *which* tags are already ticked.
    ///
    /// Fixed height, so lines are level without per-line vertical centering
    /// — and `cornerRadius(16)` on a 32pt tile is the same pill the chip row
    /// uses, which is the point.
    private func candidateTile(_ tag: String) -> some View {
        let isTicked = isTicked(tag)

        return Button {
            toggle(tag)
        } label: {
            HStack(spacing: 6) {
                Text(tag)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(viewModel.tagCount(for: tag))")
                    .font(.caption)
                    .foregroundColor(isTicked ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 44)
            .frame(height: 32)
            .background(isTicked ? Color.accentColor : Color(.systemGray6))
            .foregroundColor(isTicked ? .white : .primary)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
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
