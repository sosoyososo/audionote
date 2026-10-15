 import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @EnvironmentObject private var languageManager: LanguageManager
    @ObservedObject private var storage = StorageCoordinator.shared
    @State private var refreshId = UUID()
    @State private var selectedTab: AppTab = .recording

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
            TabView(selection: $selectedTab) {
                RecordingView(viewModel: viewModel)
                    .tabItem {
                        Label("Tab.Recording".localized(for: languageManager.current), systemImage: "mic.fill")
                    }
                    .tag(AppTab.recording)

                LibraryListView(viewModel: viewModel)
                    .tabItem {
                        Label("Tab.Library".localized(for: languageManager.current), systemImage: "list.bullet")
                    }
                    .tag(AppTab.library)

                SettingsView()
                    .tabItem {
                        Label("Tab.Settings".localized(for: languageManager.current), systemImage: "gear")
                    }
                    .tag(AppTab.settings)
            }
            .environmentObject(viewModel)
            .onChange(of: selectedTab) { tab in
                // Landing on the library tab — from another tab or by
                // re-tapping the one you're already on — always means the
                // default list. Archive mode is a mode you leave deliberately,
                // not one you can get stuck in. Search and tag filters are
                // untouched: clearing them here would throw away a query the
                // user is mid-way through typing.
                if tab == .library {
                    viewModel.isArchiveMode = false
                }
            }
        }
    }

    private enum AppTab: Hashable {
        case recording, library, settings
    }
}

#Preview {
    ContentView()
        .environmentObject(LanguageManager.shared)
}
