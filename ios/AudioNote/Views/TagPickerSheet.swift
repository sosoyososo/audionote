import SwiftUI

/// Every tag the library has, searchable.
///
/// The chip row is a horizontal scroll. That is fine for a handful of
/// tags and unusable for fifty: the tags past the fold cannot be reached
/// by tapping, there is no way to search for one, and the scroll gives no
/// hint that there is anything to the right of what you can see.
///
/// This sheet is that missing way in. It drives the **same** selection
/// state and the **same** toggle as the chips — not a second filter that
/// has to be kept in step with the first.
struct TagPickerSheet: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// The tags matching the query, in the chip row's order.
    private var matchingTags: [String] {
        let all = viewModel.availableTags
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return all
        }
        return all.filter { TagIdentity.contains($0, query: query) }
    }

    private var selectionCount: Int {
        viewModel.selectedTags.count
    }

    var body: some View {
        NavigationStack {
            List {
                if matchingTags.isEmpty {
                    Text("Library.Tags.NoMatch".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(matchingTags, id: \.self) { tag in
                        row(for: tag)
                    }
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

    private func row(for tag: String) -> some View {
        let isSelected = TagIdentity.matches(tag, anyOf: viewModel.selectedTags)
        let count = viewModel.tagCount(for: tag)

        return Button {
            viewModel.toggleTag(tag)
        } label: {
            HStack {
                Text(tag)
                    .font(.body)
                    .foregroundColor(.primary)
                Spacer()
                if count > 0 {
                    Text("\\(count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
