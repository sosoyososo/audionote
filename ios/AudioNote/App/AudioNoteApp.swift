import SwiftUI

@main
struct AudioNoteApp: App {
    @StateObject private var languageManager = LanguageManager.shared

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
