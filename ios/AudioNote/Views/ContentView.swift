import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    
    var body: some View {
        TabView {
            RecordingView(viewModel: viewModel)
                .tabItem {
                    Label("录音", systemImage: "mic.fill")
                }
            
            HistoryListView(viewModel: viewModel)
                .tabItem {
                    Label("历史记录", systemImage: "list.bullet")
                }
        }
        .environmentObject(viewModel)
    }
}

#Preview {
    ContentView()
}
