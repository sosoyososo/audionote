import SwiftUI

struct LibraryListView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @State private var selectedRecord: TranscriptionRecord?
    @State private var showDeleteConfirmation = false
    @State private var recordToDelete: TranscriptionRecord?
    @State private var searchInput: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @StateObject private var actionsViewModel = RecordActionsViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar
                tagChipsRow
                archivedBanner

                content
            }
            .navigationTitle("Tab.Library".localized)
            .refreshable { await viewModel.loadHistory() }
            .sheet(item: $selectedRecord) { record in
                NavigationView {
                    TranscriptionDetailView(
                        record: record,
                        viewModel: viewModel
                    )
                }
            }
            .alert("History.Delete.Confirm".localized, isPresented: $showDeleteConfirmation) {
                Button("Action.Cancel".localized, role: .cancel) {
                    recordToDelete = nil
                }
                Button("Action.Delete".localized, role: .destructive) {
                    if let record = recordToDelete {
                        deleteRecord(record)
                    }
                    recordToDelete = nil
                }
            } message: {
                Text("History.Delete.Message".localized)
            }
            .overlay(alignment: .top) {
                VStack {
                    ToastView(message: actionsViewModel.toastMessage, isShowing: $actionsViewModel.showCopiedToast)
                    Spacer()
                }
                .padding(.top, 60)
            }
        }
        .task {
            await viewModel.loadHistory()
        }
    }

    // MARK: - Top sections

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Library.Search.Placeholder".localized, text: $searchInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: searchInput) { newValue in
                    scheduleSearchUpdate(newValue)
                }

            if !searchInput.isEmpty {
                Button {
                    searchInput = ""
                    scheduleSearchUpdate("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var tagChipsRow: some View {
        Group {
            if viewModel.availableTags.isEmpty {
                Text("Library.NoTags".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.availableTags, id: \.self) { tag in
                            tagChip(tag)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func tagChip(_ tag: String) -> some View {
        let isSelected = viewModel.selectedTags.contains(tag)
        let count = viewModel.tagCounts[tag] ?? 0

        return Button {
            viewModel.toggleTag(tag)
        } label: {
            HStack(spacing: 6) {
                Text(tag)
                    .font(.subheadline)
                Text("\(count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        (isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                    )
                    .cornerRadius(8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(.systemGray5))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var archivedBanner: some View {
        if viewModel.archivedHitCount > 0 {
            NavigationLink {
                LibraryArchivedMatchesView(viewModel: viewModel)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox")
                    Text(String(format: "Library.ArchivedBanner".localized, viewModel.archivedHitCount))
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content (list / empty / no-results)

    @ViewBuilder
    private var content: some View {
        if viewModel.historyRecords.isEmpty {
            emptyLibraryState
        } else if viewModel.displayedRecords.isEmpty {
            noResultsState
        } else {
            recordsListView
        }
    }

    private var emptyLibraryState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("History.Empty".localized)
                .font(.headline)
                .foregroundColor(.secondary)

            Text("History.Empty.Hint".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Library.NoResults".localized)
                .font(.headline)
                .foregroundColor(.secondary)

            Button("Library.ClearFilters".localized) {
                searchInput = ""
                viewModel.clearFilters()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordsListView: some View {
        List {
            ForEach(sortedRecordGroups, id: \.dateKey) { group in
                Section(header: Text(group.dateKey)) {
                    ForEach(group.records) { record in
                        RecordRowView(record: record)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedRecord = record
                            }
                            .contextMenu {
                                contextMenuItems(for: record)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    recordToDelete = record
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Action.Delete".localized, systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { indexSet in
                        if let firstIndex = indexSet.first {
                            recordToDelete = group.records[firstIndex]
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Grouping helpers

    private var sortedRecordGroups: [RecordGroup] {
        let grouped = Dictionary(grouping: viewModel.displayedRecords) { record in
            formatDate(record.createdAt)
        }

        return grouped.map { dateKey, records in
            RecordGroup(
                dateKey: dateKey,
                date: records.first?.createdAt ?? Date(),
                records: records.sorted { $0.createdAt > $1.createdAt }
            )
        }
        .sorted { $0.date > $1.date }
    }

    private struct RecordGroup: Identifiable {
        let id = UUID()
        let dateKey: String
        let date: Date
        let records: [TranscriptionRecord]
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "History.Today".localized
        } else if calendar.isDateInYesterday(date) {
            return "History.Yesterday".localized
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "Date.Format".localized
            return formatter.string(from: date)
        }
    }

    private func deleteRecord(_ record: TranscriptionRecord) {
        viewModel.deleteRecord(id: record.id)
    }

    private func scheduleSearchUpdate(_ newValue: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms debounce
            if !Task.isCancelled {
                viewModel.setSearchQuery(newValue)
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for record: TranscriptionRecord) -> some View {
        Button {
            selectedRecord = record
        } label: {
            Label("History.ViewDetail".localized, systemImage: "eye")
        }

        Button {
            actionsViewModel.copyText(record.content)
        } label: {
            Label("Action.Copy".localized, systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            recordToDelete = record
            showDeleteConfirmation = true
        } label: {
            Label("Action.Delete".localized, systemImage: "trash")
        }
    }
}

// MARK: - Row

struct RecordRowView: View {
    let record: TranscriptionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .font(.body)
                .lineLimit(1)

            Text(displaySummary)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)

            tagsRow

            HStack(spacing: 8) {
                Text(record.createdAt, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let duration = record.duration, duration > 0 {
                    Text("History.Duration".localized + " " + record.formattedDuration)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if record.archived {
                    Text("Detail.Action.Archived".localized)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// De-emphasized inline `#tag` row. Matches the existing caption + secondary
    /// visual language used by time / duration / archived badge so tags don't
    /// out-shout the title or summary. Renders nothing when there are no tags,
    /// collapses overflow past 3 tags into `+N`.
    @ViewBuilder
    private var tagsRow: some View {
        let cleaned = record.tags?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !cleaned.isEmpty {
            let shown = Array(cleaned.prefix(3))
            let overflow = cleaned.count - shown.count
            HStack(spacing: 6) {
                ForEach(shown, id: \.self) { tag in
                    Text("#\(tag)")
                        .lineLimit(1)
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }

    private var displayTitle: String {
        if let title = record.title, !title.isEmpty {
            return title
        }
        let prefix = String(record.content.prefix(30))
        return prefix + (record.content.count > 30 ? "…" : "")
    }

    private var displaySummary: String {
        if let summary = record.summary, !summary.isEmpty {
            return summary
        }
        let skip = record.title?.isEmpty == false ? min(record.title!.count, 30) : 30
        let start = record.content.index(record.content.startIndex, offsetBy: min(skip, record.content.count))
        let remaining = String(record.content[start...])
        let slice = String(remaining.prefix(50))
        return slice.isEmpty ? record.preview : slice + (remaining.count > 50 ? "…" : "")
    }
}

// MARK: - Archived matches sub-page

struct LibraryArchivedMatchesView: View {
    @ObservedObject var viewModel: TranscriptionViewModel

    private var archivedMatches: [TranscriptionRecord] {
        let ids = Set(viewModel.archivedHitIDs)
        return viewModel.historyRecords
            .filter { ids.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        Group {
            if archivedMatches.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("Library.NoResults".localized)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(archivedMatches) { record in
                        RecordRowView(record: record)
                            .listRowBackground(Color.orange.opacity(0.05))
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Library.ArchivedSublistTitle".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    LibraryListView(viewModel: TranscriptionViewModel())
}