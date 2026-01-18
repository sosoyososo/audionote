import SwiftUI

struct TranscriptionDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var showCopiedToast = false
    @State private var isEditing: Bool
    @State private var editedContent: String = ""
    @State private var showSaveSuccess = false
    @State private var toastMessage = ""

    init(record: TranscriptionRecord, viewModel: TranscriptionViewModel, startInEditingMode: Bool = false) {
        self.record = record
        self.viewModel = viewModel
        self._isEditing = State(initialValue: startInEditingMode)
        self._editedContent = State(initialValue: record.content)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metadataSection

                    Divider()

                    contentSection
                }
                .padding()
            }
            .navigationTitle(isEditing ? "编辑内容" : "转写详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing {
                        Button("取消") {
                            cancelEditing()
                        }
                    } else {
                        Button("关闭") {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    if isEditing {
                        Button("保存") {
                            saveEditing()
                        }
                    } else {
                        HStack {
                            Button(action: copyText) {
                                Image(systemName: "doc.on.doc")
                            }

                            Button(action: { showShareSheet = true }) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [editedContent])
            }
            .overlay {
                if showCopiedToast {
                    toastView(message: toastMessage)
                }
                if showSaveSuccess {
                    toastView(message: toastMessage)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                showSaveSuccess = false
                            }
                        }
                }
            }
        }
    }

    private func toastView(message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))
                .cornerRadius(20)
                .padding(.bottom, 40)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
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

    private func copyText() {
        UIPasteboard.general.string = editedContent
        toastMessage = "已复制到剪贴板"
        withAnimation {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopiedToast = false
            }
        }
    }

    private func saveEditing() {
        let updatedRecord = TranscriptionRecord(
            id: record.id,
            content: editedContent,
            createdAt: record.createdAt,
            duration: record.duration,
            language: record.language
        )

        Task {
            do {
                try await viewModel.updateRecord(updatedRecord)
                await MainActor.run {
                    isEditing = false
                    toastMessage = "保存成功"
                    showSaveSuccess = true
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
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    let record = TranscriptionRecord(
        content: "这是一段测试文本，用于预览转写详情页面的显示效果。",
        createdAt: Date()
    )
    return TranscriptionDetailView(record: record, viewModel: TranscriptionViewModel())
}
