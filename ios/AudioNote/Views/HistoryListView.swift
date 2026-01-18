import SwiftUI

struct HistoryListView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @State private var selectedRecord: TranscriptionRecord?
    @State private var recordToDelete: TranscriptionRecord?
    @StateObject private var actionsViewModel = RecordActionsViewModel()

    var body: some View {
        NavigationView {
            Group {
                if viewModel.historyRecords.isEmpty {
                    emptyStateView
                } else {
                    recordsListView
                }
            }
            .navigationTitle("历史记录")
            .refreshable {
                await viewModel.loadHistory()
            }
            .sheet(item: $selectedRecord) { record in
                NavigationView {
                    TranscriptionDetailView(
                        record: record,
                        viewModel: viewModel
                    )
                }
            }
            .alert("确认删除", isPresented: .constant(recordToDelete != nil)) {
                Button("取消", role: .cancel) {
                    recordToDelete = nil
                }
                Button("删除", role: .destructive) {
                    if let record = recordToDelete {
                        deleteRecord(record)
                    }
                    recordToDelete = nil
                }
            } message: {
                Text("删除后无法恢复，确定要删除这条记录吗？")
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
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("暂无转写记录")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("点击底部录音按钮开始录制")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var recordsListView: some View {
        List {
            ForEach(sortedRecordGroups, id: \.dateKey) { group in
                Section(header: Text(group.dateKey)) {
                    ForEach(group.records) { record in
                        RecordRowView(record: record)
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
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { indexSet in
                        if let firstIndex = indexSet.first {
                            recordToDelete = group.records[firstIndex]
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var sortedRecordGroups: [RecordGroup] {
        let grouped = Dictionary(grouping: viewModel.historyRecords) { record in
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
            return "今天"
        } else if calendar.isDateInYesterday(date) {
            return "昨天"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            return formatter.string(from: date)
        }
    }

    private func deleteRecord(_ record: TranscriptionRecord) {
        Task {
            await viewModel.deleteRecord(id: record.id)
        }
    }

    @ViewBuilder
    private func contextMenuItems(for record: TranscriptionRecord) -> some View {
        Button {
            selectedRecord = record
        } label: {
            Label("查看详情", systemImage: "eye")
        }

        Button {
            actionsViewModel.copyText(record.content)
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            recordToDelete = record
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}

struct RecordRowView: View {
    let record: TranscriptionRecord
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.preview)
                .font(.body)
                .lineLimit(2)
            
            HStack {
                Text(record.createdAt, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let duration = record.duration, duration > 0 {
                    Text(record.formattedDuration)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    HistoryListView(viewModel: TranscriptionViewModel())
}
