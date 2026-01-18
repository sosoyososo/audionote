import SwiftUI

struct HistoryListView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @State private var selectedRecord: TranscriptionRecord?
    @State private var shouldEnterEditingMode = false

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
                TranscriptionDetailView(
                    record: record,
                    viewModel: viewModel,
                    startInEditingMode: shouldEnterEditingMode
                )
                .onDisappear {
                    shouldEnterEditingMode = false
                }
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
            ForEach(groupedRecords.keys.sorted(by: >), id: \.self) { dateKey in
                Section(header: Text(dateKey)) {
                    ForEach(groupedRecords[dateKey] ?? []) { record in
                        RecordRowView(record: record)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedRecord = record
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteRecord(record)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    shouldEnterEditingMode = true
                                    selectedRecord = record
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }
                    .onDelete { indexSet in
                        deleteRecords(at: indexSet, in: groupedRecords[dateKey] ?? [])
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private var groupedRecords: [String: [TranscriptionRecord]] {
        Dictionary(grouping: viewModel.historyRecords) { record in
            formatDate(record.createdAt)
        }
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
    
    private func deleteRecords(at indexSet: IndexSet, in records: [TranscriptionRecord]) {
        for index in indexSet {
            let record = records[index]
            deleteRecord(record)
        }
    }

    private func deleteRecord(_ record: TranscriptionRecord) {
        Task {
            await viewModel.deleteRecord(id: record.id)
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
