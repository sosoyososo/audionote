import Foundation
import Combine

/// View-model for the Settings tab. Surfaces the ProviderProfileStore for
/// the profile list / "set active" UI and provides the "测试连接" handler
/// that delegates to `LLMService.ping`.
///
/// The legacy single `audioNote:llmToken` field and the old
/// `validateLLMConfiguration` / `testLLMConnection` are gone — see
/// `docs/superpowers/specs/2026-09-24-multi-provider-llm-design.md`
/// for the migration story.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var isPinging: Bool = false
    @Published var pingResult: PingResult? = nil

    /// One-shot migration toast: shown the first time the new build sees
    /// the old single-token layout. Acknowledged after the first display.
    @Published var migrationToast: String? = nil

    private let store: ProviderProfileStore
    private let llmService = LLMService()

    enum PingResult: Equatable {
        case success
        case failure(String)
    }

    init(store: ProviderProfileStore = .shared) {
        self.store = store
        if store.needsProviderSetup {
            self.migrationToast = "Settings.LLM.Migration.Toast".localized
            store.acknowledgeNeedsSetup()
        }
    }

    // MARK: - Profile list accessors

    var profiles: [LLMProviderProfile] { store.profiles }
    var activeProfile: LLMProviderProfile? { store.active }
    var activeProfileId: UUID? { store.activeProfileId }

    // MARK: - Profile CRUD (delegated)

    func upsert(_ profile: LLMProviderProfile, apiKey: String?) {
        do {
            try store.upsert(profile, apiKey: apiKey)
        } catch {
            Logger.error("SettingsViewModel.upsert failed: \(error.localizedDescription)")
        }
    }

    func delete(_ id: UUID) {
        do {
            try store.delete(id)
        } catch {
            Logger.error("SettingsViewModel.delete failed: \(error.localizedDescription)")
        }
    }

    func setActive(_ id: UUID) {
        do {
            try store.setActive(id)
        } catch {
            Logger.error("SettingsViewModel.setActive failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Test connection (ping)

    /// Sends a minimal "ping" through the active profile. Surfaces the
    /// outcome via `pingResult`. The Settings view watches this and shows
    /// a toast on success / failure.
    func testActiveConnection() {
        guard let profile = store.active else {
            pingResult = .failure("Settings.LLM.Test.NoProfile".localized)
            return
        }
        let apiKey = store.apiKey(for: profile.id)

        isPinging = true
        pingResult = nil
        Task {
            do {
                try await llmService.ping(profile: profile, apiKey: apiKey)
                await MainActor.run {
                    self.isPinging = false
                    self.pingResult = .success
                }
            } catch let error as LLMError {
                await MainActor.run {
                    self.isPinging = false
                    self.pingResult = .failure(error.errorDescription ?? "Unknown error")
                }
            } catch {
                await MainActor.run {
                    self.isPinging = false
                    self.pingResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}
