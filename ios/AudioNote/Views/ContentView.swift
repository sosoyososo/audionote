import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @EnvironmentObject private var languageManager: LanguageManager
    @State private var refreshId = UUID()

    var body: some View {
        ZStack {
            TabView {
                RecordingView(viewModel: viewModel)
                    .tabItem {
                        Label("Tab.Recording".localized(for: languageManager.current), systemImage: "mic.fill")
                    }

                HistoryListView(viewModel: viewModel)
                    .tabItem {
                        Label("Tab.History".localized(for: languageManager.current), systemImage: "list.bullet")
                    }
            }
            .environmentObject(viewModel)
        }
        .id(refreshId)
        .onReceive(NotificationCenter.default.publisher(for: .languageChanged)) { _ in
            refreshId = UUID()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(LanguageManager.shared)
}
