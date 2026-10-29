import SwiftUI

/// Every tag the library has, searchable, as a wrapping grid of tiles.
///
/// The chip row is a horizontal scroll. That is fine for a handful of
/// tags and unusable for fifty: the tags past the fold cannot be reached
/// by tapping, there is no way to search for one, and the scroll gives no
/// hint that there is anything to the right of what you can see.
///
/// **The same shape as the merge screen** (`MergeTagsView`): tiles that
/// wrap, not one tag per row. A single column is a list with extra steps
/// — it puts one tag on a whole screen's worth of height, so finding one
/// tag means scrolling through every other tag, and the screen shows a
/// handful of them at a time. Content-sized tiles that wrap put a dozen
/// on screen at once.
///
/// The order is alphabetical, not the chip row's count order. The chips
/// are a *ranking* — the tags worth noticing float to the front. This is
/// a *lookup* — "find the tag I want" — and what makes a grid findable
/// is a position you can predict: the count ranking has none, so you
/// would read every tile to decide whether to stop. Chinese collates by
/// pinyin, English ignores case, and `Apple2` precedes `Apple10`.
///
/// It drives the **same** selection state and the **same** toggle as the
/// chips — not a second filter that has to be kept in step with the
/// first.
struct TagPickerSheet: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showProposals = false

    /// The tags matching the query, alphabetically.
    private var candidates: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.availableTags
            .filter { TagIdentity.contains($0, query: needle) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var selectionCount: Int {
        viewModel.selectedTags.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                mergeEntry

                FlowRow(spacing: 8, lineSpacing: 8) {
                    ForEach(candidates, id: \.self) { tag in
                        tile(for: tag)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if candidates.isEmpty {
                    Text("Library.Tags.NoMatch".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .searchable(text: $query, prompt: "Library.Tags.Search".localized)
            .sheet(isPresented: $showProposals) {
                TagMergeProposalSheet(viewModel: viewModel)
            }
            .navigationTitle("Library.Tags.Title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.clearTagSelection()
                    } label: {
                        Text("Library.Tags.Clear".localized)
                    }
                    .disabled(selectionCount == 0)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Library.Tags.Done".localized)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: - Smart merge

    /// The entry for the merge proposal, as a row of state rather than a
    /// button that turns into a spinner.
    ///
    /// The work belongs to the view model, not to this sheet: closing the
    /// sheet does not stop it, and the row says where it got to. Tapping it
    /// starts the run *and* opens the sheet, so the user is not left
    /// wondering whether anything happened.
    private var mergeEntry: some View {
        Button {
            if viewModel.mergeProposalState != .running {
                viewModel.startTagMergeProposal()
            }
            showProposals = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Library.Tags.Merge.Smart".localized)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(mergeEntryStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if viewModel.mergeProposalState == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
    }

    /// The one line that says what the run is doing.
    private var mergeEntryStatus: String {
        switch viewModel.mergeProposalState {
        case .idle:
            return "Library.Tags.Merge.Hint".localized
        case .running:
            return "Library.Tags.Merge.Working".localized
        case .done:
            return viewModel.mergeProposals.isEmpty
                ? "Library.Tags.Merge.Empty".localized
                : String(format: "Library.Tags.Merge.Found".localized,
                         viewModel.mergeProposals.count)
        case .cancelled:
            return "Library.Tags.Merge.Cancelled".localized
        case .failed:
            return "Library.Tags.Merge.Failed".localized
        }
    }

    /// The merge screen's tile, unchanged: the same pill, the same count,
    /// the same tick. Two screens that pick tags should look like the
    /// same control.
    private func tile(for tag: String) -> some View {
        let isSelected = TagIdentity.matches(tag, anyOf: viewModel.selectedTags)

        return Button {
            viewModel.toggleTag(tag)
        } label: {
            HStack(spacing: 6) {
                Text(tag)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(viewModel.tagCount(for: tag))")
                    .font(.caption)
                    .foregroundColor(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 44)
            .frame(height: 32)
            .background(isSelected ? Color.accentColor : Color(.systemGray6))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}
