import SwiftUI

@main
struct AudioNoteApp: App {
    @StateObject private var languageManager = LanguageManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        NetworkMonitor.shared.startMonitoring()
        // Migrate legacy single `audioNote:llmToken` UserDefaults entry into
        // the new ProviderProfileStore / Keychain layout. Idempotent.
        ProviderProfileStore.runLegacyTokenMigration()
        // Pre-resolve the Files-app bookmark so ContentView's first frame
        // already knows `StorageCoordinator.isReady`. Avoids the OnboardingView
        // flash on subsequent launches (when the bookmark is already saved).
        if let url = StorageCoordinator.shared.resolveSync() {
            StorageCoordinator.shared.setReady(url: url)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(languageManager)
                .onChange(of: languageManager.current) { _ in
                    // Force view refresh by posting notification
                    NotificationCenter.default.post(name: .languageChanged, object: nil)
                }
        }
        .onChange(of: scenePhase) { phase in
            // Files-app storage requires releasing/re-acquiring the
            // security-scoped bookmark on every phase change. Must live on
            // the WindowGroup so it fires regardless of whether the root
            // view is ContentView (isReady) or OnboardingView.
            StorageCoordinator.shared.handleScenePhase(phase)
        }
    }
}
