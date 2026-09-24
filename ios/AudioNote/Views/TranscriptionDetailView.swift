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
                HStack {
                    Image(systemName: recognitionModeIcon(for: mode))
                        .foregroundColor(recognitionModeColor(for: mode))
                    Text(recognitionModeLabel(for: mode))
                        .foregroundColor(recognitionModeColor(for: mode))
                }
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

    private func recognitionModeIcon(for mode: RecognitionMode?) -> String {
        switch mode {
        case .online: return "cloud.fill"
        case .onDevice: return "iphone.gen1"
        case .enhanced: return "cloud.fill.badge.checkmark"
        case .failed: return "xmark.shield.fill"
        case .none: return "questionmark.circle"
        }
    }

    private func recognitionModeColor(for mode: RecognitionMode?) -> Color {
        switch mode {
        case .online: return .green
        case .onDevice: return .yellow
        case .enhanced: return .blue
        case .failed: return .red
        case .none: return .secondary
        }
    }

    private func recognitionModeLabel(for mode: RecognitionMode?) -> String {
        switch mode {
        case .online: return "在线识别"
        case .onDevice: return "离线识别"
        case .enhanced: return "已在线升级"
        case .failed: return "识别失败"
        case .none: return "未知"
        }
    }

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
