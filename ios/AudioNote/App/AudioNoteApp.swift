import SwiftUI

@main
struct AudioNoteApp: App {
    @StateObject private var languageManager = LanguageManager.shared

    init() {
        NetworkMonitor.shared.startMonitoring()
        // Migrate legacy single `audioNote:llmToken` UserDefaults entry into
        // the new ProviderProfileStore / Keychain layout. Idempotent.
        ProviderProfileStore.runLegacyTokenMigration()
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
    }
}
