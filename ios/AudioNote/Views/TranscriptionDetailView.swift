import SwiftUI

struct TranscriptionDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var actionsViewModel = RecordActionsViewModel()
    @State private var isEditing = false
    @State private var editedContent: String = ""
    @State private var isProcessing = false
    @State private var localArchived: Bool = false
    @State private var relatedNotes: [RelatedNote] = []

    init(record: TranscriptionRecord, viewModel: TranscriptionViewModel) {
        self.record = record
        self.viewModel = viewModel
        self._editedContent = State(initialValue: record.content)
        self._localArchived = State(initialValue: record.archived)
    }

    /// Latest snapshot of this record from the VM. `record` is a value-type
    /// copy handed in by the sheet and never refreshes; background LLM
    /// completion updates `viewModel.historyRecords` (via `loadHistory`), so
    /// deriving from it lets the detail view reflect post-open changes
    /// without a manual sync step.
    private var currentRecord: TranscriptionRecord {
        viewModel.historyRecords.first { $0.id == record.id } ?? record
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataSection

                Divider()

                contentSection

                actionsSection
                    .padding(.top, 4)

                if let audioFileName = currentRecord.audioFileName {
                    PlaybackControlBar(audioFileName: audioFileName)
                        .padding(.top, 8)
                }

                llmResultsSection

                RelatedNotesSection(
                    rows: RelatedNotesSectionBuilder.rows(
                        for: currentRecord,
                        candidates: viewModel.historyRecords,
                        related: relatedNotes
                    ),
                    viewModel: viewModel
                )
            }
            .padding()
        }
        .navigationTitle(isEditing ? "Detail.Edit.Title".localized : "Detail.Title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isEditing {
                    Button("Action.Cancel".localized) {
                        cancelEditing()
                    }
                } else {
                    Button("Action.Close".localized) {
                        dismiss()
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button("Action.Save".localized) {
                        saveEditing()
                    }
                } else {
                    HStack {
                        Button {
                            actionsViewModel.copyText(currentRecord.content)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }

                        Button {
                            actionsViewModel.showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }

                        Button {
                            enterEditingMode()
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $actionsViewModel.showShareSheet) {
            ShareSheet(items: [currentRecord.content])
        }
        .overlay(alignment: .bottom) {
            ToastView(message: actionsViewModel.toastMessage, isShowing: $actionsViewModel.showCopiedToast)
                .padding(.bottom, 40)
        }
        .task(id: currentRecord.id) {
            // `relatedNotes.json` is the source of truth and the store has no
            // cache (spec §5.2), so this re-reads on every appear — the task
            // is cancelled and restarted when the view leaves. Loading once
            // would leave the section permanently empty for a note opened while
            // its own relation call was still in flight (1–3s window), since
            // nothing would re-read the file afterward.
            relatedNotes = await RelatedNotesStorage.shared.related(to: currentRecord.id)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.secondary)
                Text(currentRecord.createdAt, style: .date)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text(currentRecord.createdAt, style: .time)
                    .foregroundColor(.secondary)
            }

            if let duration = currentRecord.duration, duration > 0 {
                HStack {
                    Image(systemName: "timer")
                        .foregroundColor(.secondary)
                    Text(currentRecord.formattedDuration)
                        .foregroundColor(.secondary)
                }
            }

            if let mode = currentRecord.recognitionMode {
                let style = RecognitionModeStyle(mode: mode)
                HStack(spacing: 6) {
                    Image(systemName: style.icon)
                    Text(style.label)
                }
                .foregroundColor(style.color)
            }
        }
        .font(.subheadline)
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if currentRecord.optimizedContent != nil {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("优化后")
                        .font(.caption)
                        .foregroundColor(.green)
                    Spacer()
                }
            }

            Group {
                if isEditing {
                    TextEditor(text: $editedContent)
                        .font(.body)
                        .frame(minHeight: 200)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                } else {
                    Text(editedContent)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var llmResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // Show results if available
            if currentRecord.title != nil || currentRecord.summary != nil || currentRecord.tags != nil {
                if let title = currentRecord.title, !title.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detail.LLM.Title".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(title)
                            .font(.headline)
                    }
                }

                if let summary = currentRecord.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detail.LLM.Summary".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(summary)
                            .font(.body)
                    }
                }

                if let tags = currentRecord.tags, !tags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detail.LLM.Tags".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TagFlowView(tags: tags)
                    }
                }
            }

            // Status indicator and action button
            llmStatusView
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var llmStatusView: some View {
        if isProcessing || viewModel.isLLMProcessing {
            // Currently processing - show disabled button with spinner
            HStack {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                Text("Detail.LLM.Processing".localized)
            }
            .disabled(true)
        } else {
            // Show action button based on status
            Button {
                reprocessRecord()
            } label: {
                HStack {
                    Image(systemName: buttonIcon)
                    Text(buttonTitle)
                }
            }
            .disabled(viewModel.isLLMProcessing)
        }
    }

    private var buttonIcon: String {
        switch currentRecord.llmProcessingStatus {
        case .completed: return "arrow.clockwise"
        case .failed: return "exclamationmark.triangle"
        default: return "sparkles"
        }
    }

    private var buttonTitle: String {
        switch currentRecord.llmProcessingStatus {
        case .completed: return "Detail.LLM.Reprocess".localized
        case .failed: return "Detail.LLM.Failed".localized
        default: return "Detail.LLM.Start".localized
        }
    }

    // MARK: - Recognition Mode Helpers
//
// `RecognitionModeStyle` lives in `SharedComponents.swift` and is the
// single source of truth for mode → {icon, color, label}. This view
// consumes it via the `if let mode = currentRecord.recognitionMode`
// binding above — no per-view helper duplication.

    @ViewBuilder
    private var actionsSection: some View {
        HStack(spacing: 8) {
            if let mode = currentRecord.recognitionMode,
               (mode == .onDevice || mode == .failed),
               currentRecord.audioFileName != nil {
                Button {
                    upgradeRecognition()
                } label: {
                    HStack {
                        if viewModel.isEnhancing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.up.doc")
                        }
                        Text("在线升级识别")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.isEnhancing)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .cornerRadius(10)
            } else {
                Spacer()
            }

            archiveButton
        }
    }

    private var archiveButton: some View {
        Button {
            archiveToggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: localArchived ? "archivebox.fill" : "archivebox")
                Text(localArchived
                     ? "Detail.Action.Archived".localized
                     : "Detail.Action.Archive".localized)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(localArchived ? Color.orange.opacity(0.25) : Color.gray.opacity(0.1))
            .foregroundColor(localArchived ? .orange : .primary)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func archiveToggle() {
        let nextState = !localArchived
        localArchived = nextState
        Task {
            if nextState {
                await viewModel.archiveRecord(id: record.id)
            } else {
                await viewModel.unarchiveRecord(id: record.id)
            }
        }
    }

    private func upgradeRecognition() {
        Task {
            await viewModel.reRecognizeOnline(recordId: record.id)
            // VM.reRecognizeOnline ends with loadHistory(); currentRecord
            // will pick up the refreshed recognitionMode + content on the
            // next render — no manual sync needed here.
        }
    }

    private func reprocessRecord() {
        isProcessing = true
        Task {
            let baseRecord = currentRecord
            let originalText = baseRecord.optimizedContent ?? baseRecord.content

            // This view is NOT a route through `processWithLLM` — it calls
            // `optimizeAndProcess` itself, so it carries its own copy of the
            // empty-text guard. A `.pending` record reaches this screen
            // (`displayedRecords` filters on archived / search / tags only)
            // with `content == ""` and `llmProcessingStatus == nil`, which
            // is exactly the state that gets `llmStatusView` to render a
            // tappable button. Without this guard the model would answer
            // `""` with an invented title, summary and tags, and those would
            // be written over the record and stamped `.completed`, while the
            // later recognition retry would fix only `content`.
            //
            // Deliberately before the profile lookup: a record with no text
            // does not need a provider configured in order to be rejected.
            // Resets `isProcessing` the same way the missing-profile path
            // below does, because it is set at the top of this function.
            guard PendingRecognitionPolicy.isLLMEligible(text: originalText) else {
                Logger.warning("LLM reprocess skipped: empty text for record \(baseRecord.id)")
                await MainActor.run {
                    isProcessing = false
                }
                return
            }

            // Pull the active profile + key from the store. If no profile
            // is configured, surface that as a status without throwing.
            guard let profile = ProviderProfileStore.shared.active else {
                Logger.warning("LLM reprocess skipped: no active profile")
                await MainActor.run {
                    isProcessing = false
                }
                return
            }
            let apiKey = ProviderProfileStore.shared.apiKey(for: profile.id)
            let llmService = LLMService()

            do {
                let result = try await llmService.optimizeAndProcess(originalText, profile: profile, apiKey: apiKey)
                let updatedRecord = TranscriptionRecord(
                    id: baseRecord.id,
                    content: result.optimizedText,
                    createdAt: baseRecord.createdAt,
                    duration: baseRecord.duration,
                    language: baseRecord.language,
                    audioFileName: baseRecord.audioFileName,
                    title: result.title,
                    summary: result.summary,
                    tags: result.tags,
                    llmProcessingStatus: .completed,
                    optimizedContent: originalText != baseRecord.content ? originalText : baseRecord.optimizedContent,
                    recognitionMode: baseRecord.recognitionMode
                )
                try await viewModel.updateRecord(updatedRecord)
                await MainActor.run {
                    isProcessing = false
                    editedContent = result.optimizedText
                }
            } catch {
                Logger.error("LLM reprocess failed: \(error.localizedDescription)")
                await MainActor.run {
                    isProcessing = false
                }
            }
        }
    }

    private func saveEditing() {
        let baseRecord = currentRecord
        let updatedRecord = TranscriptionRecord(
            id: baseRecord.id,
            content: editedContent,
            createdAt: baseRecord.createdAt,
            duration: baseRecord.duration,
            language: baseRecord.language,
            audioFileName: baseRecord.audioFileName,
            title: baseRecord.title,
            summary: baseRecord.summary,
            tags: baseRecord.tags,
            llmProcessingStatus: baseRecord.llmProcessingStatus,
            recognitionMode: baseRecord.recognitionMode
        )

        Task {
            do {
                try await viewModel.updateRecord(updatedRecord)
                await MainActor.run {
                    isEditing = false
                    actionsViewModel.showSaveConfirmation()
                }
            } catch {
                Logger.error("Failed to save edited content: \(error.localizedDescription)")
            }
        }
    }

    private func cancelEditing() {
        editedContent = currentRecord.content
        isEditing = false
    }

    private func enterEditingMode() {
        editedContent = currentRecord.content
        isEditing = true
    }
}

struct RelatedNotesRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let preview: String
    let sharedTags: [String]
    /// The record a `NavigationLink` pushes. Carried here so the row stays a
    /// plain value the builder can construct without a view model.
    let record: TranscriptionRecord
}

/// Pure mapping from stored edges to renderable rows, so the skip rules are
/// unit-testable without instantiating a SwiftUI view.
enum RelatedNotesSectionBuilder {

    static func rows(
        for record: TranscriptionRecord,
        candidates: [TranscriptionRecord],
        related: [RelatedNote]
    ) -> [RelatedNotesRow] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentTagNames = Set(record.tagNames)

        // `related(to:)` already hands back score-descending edges, so this
        // sort is a no-op in production. It is kept, with the *same*
        // `uuidString` tie-break as the storage, so the rendered order cannot
        // drift from the stored one — and so the builder is well-defined for
        // any `related` input rather than trusting its caller's ordering.
        let ordered = related.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return ordered.compactMap { link -> RelatedNotesRow? in
            guard let other = byID[link.id], other.archived != true else { return nil }
            // Exact, case-sensitive intersection — deliberately the same match
            // `RelatedNotesService.prescreen` uses. A chip the prescreen never
            // matched would read as a contradiction; normalize both or neither.
            let shared = other.tagNames.filter { currentTagNames.contains($0) }
            return RelatedNotesRow(
                id: other.id,
                title: other.title?.isEmpty == false ? other.title! : other.preview,
                createdAt: other.createdAt,
                preview: other.preview,
                sharedTags: shared,
                record: other
            )
        }
    }
}

/// Rendered at the bottom of the detail page. Hides itself entirely when
/// there is nothing to show — no empty state, no spinner. Takes the view model
/// separately so `RelatedNotesRow` stays a plain value.
struct RelatedNotesSection: View {
    let rows: [RelatedNotesRow]
    @ObservedObject var viewModel: TranscriptionViewModel

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Related.Section.Title".localized)
                    .font(.headline)

                ForEach(rows) { row in
                    NavigationLink {
                        TranscriptionDetailView(record: row.record, viewModel: viewModel)
                    } label: {
                        RelatedNotesRowView(row: row)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct RelatedNotesRowView: View {
    let row: RelatedNotesRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)

            HStack(spacing: 6) {
                Text(row.createdAt, style: .date)
                Text(row.createdAt, style: .time)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Text(row.preview)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)

            if !row.sharedTags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(row.sharedTags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct TagFlowView: View {
    let tags: [TaggedItem]

    /// Tags sorted by relevance score descending. The LLM is *instructed* to
    /// return them sorted, but doesn't reliably honor that — sorting here
    /// guarantees the most relevant tag renders first regardless of what the
    /// model returns.
    private var sortedTags: [TaggedItem] {
        tags.sorted { $0.score > $1.score }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sortedTags, id: \.name) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name)
                            .font(.caption)
                        Text(String(format: "%.2f", tag.score))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
    }
}

#Preview {
    NavigationView {
        let record = TranscriptionRecord(
            content: "这是一段测试文本，用于预览转写详情页面的显示效果。",
            createdAt: Date()
        )
        TranscriptionDetailView(record: record, viewModel: TranscriptionViewModel())
    }
}
