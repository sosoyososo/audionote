import SwiftUI

struct LibraryListView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @State private var selectedRecord: TranscriptionRecord?
    @State private var showDeleteConfirmation = false
    @State private var recordToDelete: TranscriptionRecord?
    @State private var searchInput: String = ""
    @State private var isTagPickerPresented = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var mergeTarget: MergeTagTarget?
    @StateObject private var actionsViewModel = RecordActionsViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar
                tagChipsRow
                filterStatusBar

                content
            }
            .navigationTitle(navigationTitle)
            .navigationCountSubtitle(navigationSubtitle, title: navigationTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    archiveToggle
                }
            }
            .refreshable { await viewModel.loadHistory() }
            .sheet(item: $selectedRecord) { record in
                NavigationView {
                    TranscriptionDetailView(
                        record: record,
                        viewModel: viewModel
                    )
                }
            }
            .sheet(item: $mergeTarget) { target in
                MergeTagsView(target: target.name, viewModel: viewModel)
            }
            .sheet(isPresented: $isTagPickerPresented) {
                TagPickerSheet(viewModel: viewModel)
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

    /// The filters that are in effect, in one place, always visible.
    ///
    /// The chip row is a *picker*: it shows every tag and highlights the
    /// selected ones. That is enough to change a filter and not enough
    /// to *see* one — the selected chip can be a long way down a
    /// horizontal scroll, and a tag whose records the search does not
    /// match is not in the row at all, so the filter is silently applied
    /// and invisible.
    ///
    /// This bar is the state the picker edits: the selected tags, each
    /// removable, and one button to clear them all. It appears only when
    /// something is selected, so it costs no space the rest of the time.
    ///
    /// It sits **below** the tag row, directly above the list. Two reasons,
    /// and the second is the one that decided it:
    ///
    /// It keeps the two filter *controls* — the search field and the tag
    /// row — one unbroken block at the top. Putting the bar between them
    /// made three things out of two, and the state appeared *above* the
    /// control it belongs to, so a selection you had just made popped up
    /// somewhere you were not looking.
    ///
    /// And down here it reads as what it is: a caption on the results.
    /// "The list below is filtered by these" is what it says, and it says
    /// it by being right above the list. It also appears under the finger
    /// that just made the selection.
    private var filterStatusBar: some View {
        Group {
            if !viewModel.selectedTags.isEmpty {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(sortedSelectedTags, id: \.self) { tag in
                                activeFilterChip(tag)
                            }
                        }
                    }

                    // How many of the records the search already matched
                    // survive the tag filter — "5 of 8", Mail's way. The
                    // denominator is the *search* scope, not the whole
                    // library: the tags are not what hid the other three,
                    // the search box was, and a number that mixed the two
                    // would blame the wrong control.
                    Text(String(format: "Library.Filter.Count".localized,
                                viewModel.filteredRecordCount,
                                viewModel.searchMatchedCountInScope))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .monospacedDigit()

                    // Pinned outside the scroll, like the "all tags" button:
                    // the one thing that must always be reachable is the
                    // one thing that cancels everything.
                    Button {
                        viewModel.clearTagSelection()
                    } label: {
                        Text("Library.Tags.Clear".localized)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(.systemGray6).opacity(0.5))
            }
        }
    }

    /// `selectedTags` is a `Set`, so its order is whatever the hash
    /// happens to be — which would make the bar reshuffle between two
    /// renders of the same selection.
    private var sortedSelectedTags: [String] {
        viewModel.selectedTags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func activeFilterChip(_ tag: String) -> some View {
        Button {
            viewModel.toggleTag(tag)
        } label: {
            HStack(spacing: 4) {
                Text(tag)
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(Color.accentColor.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.15))
            .foregroundColor(Color.accentColor)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.availableTags, id: \.self) { tag in
                                tagChip(tag)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }

                    // Pinned **outside** the scroll. A button at the end of
                    // the scroll would be the one thing the user cannot
                    // reach — which is the whole problem. This one is always
                    // in the same place, and it says how many tags are over
                    // there, so the row no longer hides what it has.
                    Button {
                        isTagPickerPresented = true
                    } label: {
                        Text(String(format: "Library.Tags.All".localized, viewModel.availableTags.count))
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Color.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                            .padding(.trailing, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tagChip(_ tag: String) -> some View {
        let isSelected = TagIdentity.matches(tag, anyOf: viewModel.selectedTags)
        let count = viewModel.tagCount(for: tag)

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
        .contextMenu {
            // Long-press rather than a visible affordance: folding tags is a
            // repair action for a library that has drifted, not something to
            // offer on every chip on every screen.
            Button("Library.MergeTags.Action".localized) {
                mergeTarget = MergeTagTarget(name: tag)
            }
        }
    }

    /// Archive lives in the navigation bar rather than as a banner above the
    /// list: it takes no vertical space, so a rarely-visited archive cannot
    /// push the records the user did *not* archive off the screen.
    private var archiveToggle: some View {
        Button {
            viewModel.isArchiveMode.toggle()
        } label: {
            Image(systemName: viewModel.isArchiveMode ? "archivebox.fill" : "archivebox")
        }
        .disabled(!viewModel.canToggleArchiveMode)
        .badge(viewModel.archivedRecordCount)
    }

    /// The title names the list; the subtitle sizes it.
    ///
    /// The title doubles as the archive-mode indicator — it is the one element
    /// guaranteed to be on screen whenever the list looks different from usual.
    ///
    /// The count used to be inline — "思录 · 32" — which gives the number the
    /// same weight as the name, and the name is the thing being read. As a
    /// subtitle the number is a caption on the title.
    ///
    /// The count is the *unfiltered* size of this side of the library: the
    /// title says how big this side is, not how many rows happen to be on
    /// screen, so it does not jump when a filter is applied. The filtered
    /// count lives in the filter bar right below, where it can be read
    /// together with the tags that caused it.
    private var navigationTitle: String {
        viewModel.isArchiveMode
            ? "Library.ArchiveModeTitle.Plain".localized
            : "Tab.Library".localized
    }

    private var navigationSubtitle: String {
        String(format: "Library.Count.Subtitle".localized,
               viewModel.recordCountInScope)
    }

    // MARK: - Content (list / empty / no-results)

    @ViewBuilder
    private var content: some View {
        if let reason = viewModel.recordsAbsentReason {
            recordsAbsentState(reason)
        } else if !viewModel.hasRecordsInScope {
            scopeEmptyState
        } else if viewModel.displayedRecords.isEmpty {
            noResultsState
        } else {
            recordsListView
        }
    }

    /// The library file is there but could not be read.
    ///
    /// This is deliberately NOT the empty state. "没有记录" and "读不出来"
    /// render identically on screen, and the user reads the first one as
    /// "my data is gone" — which, in the corrupted case, it is not. The
    /// audio files are still sitting in the folder, and saying so is the
    /// difference between "recoverable" and "give up".
    @ViewBuilder
    private func recordsAbsentState(_ reason: RecordsAbsentReason) -> some View {
        switch reason {
        case .corrupted:
            EmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Library.LoadFailed.Corrupted.Title".localized,
                subtitle: "Library.LoadFailed.Corrupted.Hint".localized,
                actionTitle: "Library.LoadFailed.Retry".localized,
                action: { Task { await viewModel.loadHistory() } }
            )
        case .unreadable(let message):
            EmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Library.LoadFailed.Unreadable.Title".localized,
                subtitle: message,
                actionTitle: "Library.LoadFailed.Retry".localized,
                action: { Task { await viewModel.loadHistory() } }
            )
        case .orphanedAudio(let count):
            EmptyState(
                systemImage: "waveform.badge.exclamationmark",
                title: "Library.OrphanedAudio.Title".localized,
                subtitle: String(
                    format: "Library.OrphanedAudio.Hint".localized,
                    count
                )
            )
        }
    }

    @ViewBuilder
    private var scopeEmptyState: some View {
        if viewModel.isArchiveMode {
            EmptyState(
                systemImage: "archivebox",
                title: "Library.ArchiveEmpty".localized
            )
        } else {
            emptyLibraryState
        }
    }

    private var emptyLibraryState: some View {
        EmptyState(
            systemImage: "list.bullet.clipboard",
            title: "History.Empty".localized,
            subtitle: "History.Empty.Hint".localized
        )
    }

    private var noResultsState: some View {
        EmptyState(
            systemImage: "magnifyingglass",
            title: "Library.NoResults".localized,
            actionTitle: "Library.ClearFilters".localized,
            action: {
                searchInput = ""
                viewModel.clearFilters()
            }
        )
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
    /// collapses overflow past 3 tags into `+N`. Sort order: LLM-provided
    /// relevance score descending (so the most relevant tag comes first).
    @ViewBuilder
    private var tagsRow: some View {
        let cleaned = (record.tags ?? [])
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.score > $1.score }
        if !cleaned.isEmpty {
            let shown = Array(cleaned.prefix(3))
            let overflow = cleaned.count - shown.count
            HStack(spacing: 6) {
                ForEach(shown, id: \.name) { tag in
                    Text("#\(tag.name)")
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
        Self.rowTitle(for: record)
    }

    private var displaySummary: String {
        Self.rowSummary(for: record)
    }

    /// The bold first line. Extracted as a static so it can be tested
    /// without a view: a pending record has neither `title` nor `content`,
    /// and without the fallback below this returns "" — N pending rows
    /// rendering as N identical blank lines.
    static func rowTitle(for record: TranscriptionRecord) -> String {
        if let title = record.title, !title.isEmpty {
            return title
        }
        if record.content.isEmpty {
            return record.recognitionMode.map { RecognitionModeStyle(mode: $0).label }
                ?? "History.Untitled".localized
        }
        let prefix = String(record.content.prefix(30))
        return prefix + (record.content.count > 30 ? "…" : "")
    }

    /// The de-emphasized second line. `record.preview` already returns a
    /// `content` slice — but for empty content it returns the hardcoded
    /// literal `"(无内容)"`, not `""`, so the empty case is branched
    /// explicitly above rather than delegated.
    static func rowSummary(for record: TranscriptionRecord) -> String {
        if let summary = record.summary, !summary.isEmpty {
            return summary
        }
        if record.content.isEmpty {
            return record.recognitionMode == .pending
                ? "History.PendingSummary".localized
                : ""
        }
        let skip = record.title?.isEmpty == false ? min(record.title!.count, 30) : 30
        let start = record.content.index(record.content.startIndex,
                                         offsetBy: min(skip, record.content.count))
        let remaining = String(record.content[start...])
        let slice = String(remaining.prefix(50))
        return slice.isEmpty ? record.preview : slice + (remaining.count > 50 ? "…" : "")
    }
}

private extension View {
    /// A caption under the navigation title.
    ///
    /// iOS 26 has a slot for exactly this. Below that the same two lines are
    /// drawn by hand in a principal toolbar item — and a principal item
    /// *replaces* the title rather than sitting under it, so it has to carry
    /// both lines itself. The fallback is why the title is passed along: the
    /// title on screen must be the same text in both paths, and there is one
    /// source for it.
    @ViewBuilder
    func navigationCountSubtitle(_ subtitle: String, title: String) -> some View {
        if #available(iOS 26.0, *) {
            navigationSubtitle(Text(subtitle))
        } else {
            toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title)
                            .font(.headline)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

#Preview {
    LibraryListView(viewModel: TranscriptionViewModel())
}