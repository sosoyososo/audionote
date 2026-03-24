import SwiftUI

struct TranscriptionDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var actionsViewModel = RecordActionsViewModel()
    @State private var isEditing = false
    @State private var editedContent: String = ""
    @State private var isProcessing = false

    init(record: TranscriptionRecord, viewModel: TranscriptionViewModel) {
        self.record = record
        self.viewModel = viewModel
        self._editedContent = State(initialValue: record.content)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataSection

                Divider()

                contentSection

                if let audioFileName = record.audioFileName {
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
                            actionsViewModel.copyText(record.content)
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
            ShareSheet(items: [record.content])
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
                Text(record.createdAt, style: .date)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text(record.createdAt, style: .time)
                    .foregroundColor(.secondary)
            }

            if let duration = record.duration, duration > 0 {
                HStack {
                    Image(systemName: "timer")
                        .foregroundColor(.secondary)
                    Text(record.formattedDuration)
                        .foregroundColor(.secondary)
                }
            }
        }
        .font(.subheadline)
    }

    private var contentSection: some View {
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

    private var llmResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // Show results if available
            if record.title != nil || record.summary != nil || record.tags != nil {
                if let title = record.title, !title.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detail.LLM.Title".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(title)
                            .font(.headline)
                    }
                }

                if let summary = record.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detail.LLM.Summary".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(summary)
                            .font(.body)
                    }
                }

                if let tags = record.tags, !tags.isEmpty {
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
        let status = record.llmProcessingStatus

        switch status {
        case .none, .pending:
            // Never processed or pending - show start button
            Button {
                reprocessRecord()
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Detail.LLM.Start".localized)
                }
            }

        case .processing:
            // Currently processing - show disabled button with spinner
            Button {
                // No action
            } label: {
                HStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                    Text("Detail.LLM.Processing".localized)
                }
            }
            .disabled(true)

        case .completed:
            // Already completed - show reprocess button
            Button {
                reprocessRecord()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Detail.LLM.Reprocess".localized)
                }
            }

        case .failed:
            // Failed - show retry button
            Button {
                reprocessRecord()
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Detail.LLM.Failed".localized)
                }
            }
        }
    }

    private func reprocessRecord() {
        isProcessing = true
        Task {
            let service = AIProcessingService()
            _ = await service.processRecord(record)
            await MainActor.run {
                isProcessing = false
            }
            await viewModel.loadHistory()
        }
    }

    private func saveEditing() {
        let updatedRecord = TranscriptionRecord(
            id: record.id,
            content: editedContent,
            createdAt: record.createdAt,
            duration: record.duration,
            language: record.language,
            audioFileName: record.audioFileName,
            title: record.title,
            summary: record.summary,
            tags: record.tags,
            llmProcessingStatus: record.llmProcessingStatus
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
        editedContent = record.content
        isEditing = false
    }

    private func enterEditingMode() {
        editedContent = record.content
        isEditing = true
    }
}

struct TagFlowView: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
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
