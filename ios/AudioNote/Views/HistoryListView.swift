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
            .navigationTitle("History.Title".localized)
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
            .alert("History.Delete.Confirm".localized, isPresented: .constant(recordToDelete != nil)) {
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
    
    private var emptyStateView: some View {
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
                                    Label("Action.Delete".localized, systemImage: "trash")
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
        Task {
            await viewModel.deleteRecord(id: record.id)
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
        } label: {
            Label("Action.Delete".localized, systemImage: "trash")
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
