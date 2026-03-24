import Foundation
import Combine

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var llmToken: String = ""
    @Published var showSaveConfirmation: Bool = false

    private let tokenKey = "llm.api.token"

    init() {
        loadToken()
    }

    func loadToken() {
        llmToken = UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }

    func saveToken() {
        UserDefaults.standard.set(llmToken, forKey: tokenKey)
        showSaveConfirmation = true

        // Reset confirmation after delay
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showSaveConfirmation = false
        }
    }

    var hasToken: Bool {
        !llmToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
