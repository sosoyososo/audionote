import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @StateObject private var languageManager = LanguageManager.shared
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
            .environmentObject(languageManager)

            // Language changed toast
            if languageManager.showLanguageChangedToast {
                ToastView(message: NSLocalizedString("Toast.Restart", comment: ""), isShowing: $languageManager.showLanguageChangedToast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: languageManager.showLanguageChangedToast)
        .id(refreshId)
        .onAppear {
            languageManager.apply(languageManager.current)
        }
        .onReceive(NotificationCenter.default.publisher(for: .languageChanged)) { _ in
            refreshId = UUID()
        }
    }
}

#Preview {
    ContentView()
}
