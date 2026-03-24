import Foundation
import Combine

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var llmToken: String = ""
    @Published var showSaveConfirmation: Bool = false

    private let tokenKey = "audioNote:llmToken"

    init() {
        loadToken()
    }

    func loadToken() {
        llmToken = UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }

    func saveToken() {
        UserDefaults.standard.set(llmToken, forKey: tokenKey)
        showSaveConfirmation = true
    }

    var hasToken: Bool {
        !llmToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
