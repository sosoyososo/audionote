import Foundation
import Combine

/// User-managed LLM provider profiles. Profiles are stored in UserDefaults
/// as JSON; per-profile API keys live in the Keychain via `KeychainStore`.
///
/// Exactly one profile can be `active` at a time. `LLMService` reads
/// `active` + `apiKey(for:)` to make calls; nothing else in the app should
/// reach into UserDefaults directly.
///
/// Migration: on first run after upgrading from a build that used the legacy
/// single `audioNote:llmToken` key, `runLegacyTokenMigration()` clears that
/// key, disables LLM optimization, and sets `needsProviderSetup = true`.
/// SettingsViewModel surfaces a one-shot toast when that flag is set.
///
/// See `docs/superpowers/specs/2026-09-24-multi-provider-llm-design.md`
/// and `docs/decisions/0003-multi-provider-llm.md`.
@MainActor
final class ProviderProfileStore: ObservableObject {
    static let shared = ProviderProfileStore()

    @Published private(set) var profiles: [LLMProviderProfile] = []
    @Published private(set) var activeProfileId: UUID? = nil
    @Published private(set) var needsProviderSetup: Bool = false

    // MARK: - Keys

    private enum Keys {
        static let profiles = "audioNote:llmProfiles"
        static let activeId = "audioNote:activeLLMProfileId"
        static let needsSetup = "audioNote:llmNeedsProviderSetup"
        // Legacy key — only read by `runLegacyTokenMigration`, never written.
        static let legacyToken = "audioNote:llmToken"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = .shared
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.profiles = Self.loadProfiles(from: defaults)
        self.activeProfileId = Self.loadActiveId(from: defaults)
        self.needsProviderSetup = defaults.bool(forKey: Keys.needsSetup)

        // If the stored active id points at a profile that no longer exists,
        // clear it so the UI doesn't display a phantom ✓.
        if let id = activeProfileId, !profiles.contains(where: { $0.id == id }) {
            activeProfileId = nil
            defaults.removeObject(forKey: Keys.activeId)
        }
    }

    // MARK: - CRUD

    /// Inserts (or replaces, if `profile.id` already exists) a profile.
    /// `apiKey` is written to Keychain when non-nil and non-empty; pass nil
    /// for profiles where `requiresAPIKey == false`, or to leave an existing
    /// key untouched on update.
    func upsert(_ profile: LLMProviderProfile, apiKey: String?) throws {
        var didReplace = false
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            didReplace = true
        } else {
            profiles.append(profile)
        }

        if let apiKey, !apiKey.isEmpty {
            try keychain.set(apiKey, account: profile.id.uuidString)
        }

        try persistProfiles()

        // First-ever profile is auto-activated so the LLM path actually works
        // without forcing the user to tap "set active" before they can record.
        if activeProfileId == nil {
            try setActive(profile.id)
        }

        // Successful write counts as setup done.
        if needsProviderSetup {
            needsProviderSetup = false
            defaults.set(false, forKey: Keys.needsSetup)
        }
        _ = didReplace // silence unused warning; kept for future telemetry
    }

    /// Deletes the profile + its Keychain entry. If it was active, clears
    /// `activeProfileId` (the Settings UI should disable the optimize toggle
    /// in response — see `LLMOptimizationGate`).
    func delete(_ id: UUID) throws {
        profiles.removeAll { $0.id == id }
        try? keychain.delete(account: id.uuidString)
        if activeProfileId == id {
            activeProfileId = nil
            defaults.removeObject(forKey: Keys.activeId)
        }
        try persistProfiles()
    }

    // MARK: - Active

    func setActive(_ id: UUID?) throws {
        if let id, !profiles.contains(where: { $0.id == id }) {
            // Setting a non-existent profile as active is a programmer error.
            return
        }
        activeProfileId = id
        if let id {
            defaults.set(id.uuidString, forKey: Keys.activeId)
        } else {
            defaults.removeObject(forKey: Keys.activeId)
        }
    }

    var active: LLMProviderProfile? {
        guard let id = activeProfileId else { return nil }
        return profiles.first { $0.id == id }
    }

    func apiKey(for id: UUID) -> String? {
        do {
            return try keychain.get(account: id.uuidString)
        } catch {
            Logger.error("ProviderProfileStore: Keychain read failed for \(id): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Migration

    /// One-shot cleanup of the legacy single-token UserDefaults key. Idempotent.
    /// Called from `AudioNoteApp.init`.
    static func runLegacyTokenMigration(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = .shared
    ) {
        if defaults.string(forKey: Keys.legacyToken) != nil {
            defaults.removeObject(forKey: Keys.legacyToken)
            defaults.set(false, forKey: "audioNote:enableLLMOptimization")
            defaults.set(true, forKey: Keys.needsSetup)
            Logger.info("ProviderProfileStore: legacy audioNote:llmToken cleared, optimization disabled, needsProviderSetup=true")
        }
        // Touch the keychain store so unused-account cleanup can be a future op.
        _ = keychain
    }

    /// Clears the one-shot setup toast flag. Called by SettingsViewModel
    /// once the toast has been displayed so it doesn't reappear next launch.
    func acknowledgeNeedsSetup() {
        guard needsProviderSetup else { return }
        needsProviderSetup = false
        defaults.set(false, forKey: Keys.needsSetup)
    }

    // MARK: - Persistence

    private func persistProfiles() throws {
        let data = try JSONEncoder().encode(profiles)
        defaults.set(data, forKey: Keys.profiles)
    }

    private static func loadProfiles(from defaults: UserDefaults) -> [LLMProviderProfile] {
        guard let data = defaults.data(forKey: Keys.profiles) else { return [] }
        return (try? JSONDecoder().decode([LLMProviderProfile].self, from: data)) ?? []
    }

    private static func loadActiveId(from defaults: UserDefaults) -> UUID? {
        guard let s = defaults.string(forKey: Keys.activeId) else { return nil }
        return UUID(uuidString: s)
    }
}
