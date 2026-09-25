 import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @EnvironmentObject private var languageManager: LanguageManager
    @ObservedObject private var storage = StorageCoordinator.shared
    @State private var refreshId = UUID()

    var body: some View {
        Group {
            if storage.isReady {
                mainTabContentView
            } else {
                OnboardingView()
            }
        }
        .id(refreshId)
        .onReceive(NotificationCenter.default.publisher(for: .languageChanged)) { _ in
            refreshId = UUID()
        }
        .onAppear {
            // Resolve the Files-app bookmark the first time we land on the
            // root view. Sets `isReady`; the gate above swaps to the main UI
            // (or stays on OnboardingView if no bookmark exists yet).
            Task { await StorageCoordinator.shared.bootstrap() }
        }
    }

    private var mainTabContentView: some View {
        ZStack {
            TabView {
                RecordingView(viewModel: viewModel)
                    .tabItem {
                        Label("Tab.Recording".localized(for: languageManager.current), systemImage: "mic.fill")
                    }

                LibraryListView(viewModel: viewModel)
                    .tabItem {
                        Label("Tab.Library".localized(for: languageManager.current), systemImage: "list.bullet")
                    }

                SettingsView()
                    .tabItem {
                        Label("Tab.Settings".localized(for: languageManager.current), systemImage: "gear")
                    }
            }
            .environmentObject(viewModel)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(LanguageManager.shared)
}
