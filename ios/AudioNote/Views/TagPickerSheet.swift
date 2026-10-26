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
