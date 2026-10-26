import Foundation
import Combine

/// User-managed LLM provider profiles.
///
/// **Where the profiles live.** They are stored in the user's data folder
/// (`profiles.json`), not in `UserDefaults`. A profile's `id` is the
/// Keychain *account* its API key is stored under, and `UserDefaults`
/// dies with the app: after a reinstall the profiles were gone while
/// their API keys were still in the Keychain, orphaned, and the user had
/// to re-type the key. With the profiles in the folder, the ids come
/// back with it and the keys are found again.
///
/// The API key itself stays in the Keychain and never comes near the
/// folder — the folder syncs, gets copied to a computer and gets
/// shared; a secret in it is a leak.
///
/// Exactly one profile can be `active` at a time. `LLMService` reads
/// `active` + `apiKey(for:)` to make calls; nothing else in the app
/// should reach into the storage directly.
///
/// **Loading.** The profiles are read from the folder, which is a
/// user-visible FileProvider location and can be slow, so the read is
/// asynchronous. Call `ensureLoaded()` before reading `profiles` or
/// `active`; it is idempotent and safe to await from several places at
/// once.
///
/// Migration: on first run after upgrading from a build that kept the
/// profiles in `UserDefaults`, the profiles are copied into the folder
/// **preserving their ids**, so the API keys already in the Keychain
/// keep working. A build from before the multi-provider layout also
/// still has the legacy single `audioNote:llmToken` key, which
/// `runLegacyTokenMigration()` clears and turns into `needsProviderSetup`.
///
/// See `docs/superpowers/specs/2026-09-24-multi-provider-llm-design.md`
/// and `docs/decisions/0003-multi-provider-llm.md`, plus
/// `docs/decisions/0008-provider-profiles-in-the-data-folder.md`.
@MainActor
final class ProviderProfileStore: ObservableObject {
    static let shared = ProviderProfileStore()

    @Published private(set) var profiles: [LLMProviderProfile] = []
    @Published private(set) var activeProfileId: UUID? = nil
    @Published private(set) var needsProviderSetup: Bool = false

    /// False until the first load finishes.
    ///
    /// The settings screen shows a loading state rather than "no
    /// providers configured" in the window before the read completes —
    /// otherwise every launch would flash a setup prompt at a user who
    /// has already set everything up.
    @Published private(set) var isLoaded: Bool = false

    // MARK: - Keys

    private enum Keys {
        /// Legacy location of the profiles, before they moved into the
        /// data folder. Read once, for the migration, then cleared.
        static let profiles = "audioNote:llmProfiles"
        /// Legacy location of the active profile id. Same.
        static let activeId = "audioNote:activeLLMProfileId"
        /// Still here: a one-shot flag for this installation, telling the
        /// settings screen to show the "set up a provider" toast. It is
        /// per-installation UI state, not configuration, so it does not
        /// belong in the folder.
        static let needsSetup = "audioNote:llmNeedsProviderSetup"
        // Legacy key — only read by `runLegacyTokenMigration`, never written.
        static let legacyToken = "audioNote:llmToken"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let storage: ProviderProfileStorage

    /// The in-flight load, so concurrent callers wait for one read
    /// instead of starting several.
    private var loadTask: Task<Void, Never>?

    /// The legacy copy has been read but could not be written to the
    /// folder yet. The migration is retried on the next load.
    private var migrationPending = false

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = .shared,
        storage: ProviderProfileStorage = .shared
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.storage = storage
        self.needsProviderSetup = defaults.bool(forKey: Keys.needsSetup)
    }

    // MARK: - Loading

    /// Load the profiles from the data folder.
    ///
    /// Idempotent, and safe to await from several places at once: the
    /// first caller starts the read and the rest wait for it.
    func ensureLoaded() async {
        if isLoaded && !migrationPending { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        switch await storage.loadOutcome() {
        case .payload(let payload):
            apply(payload)
            // The folder is the source of truth now. The legacy copy is
            // redundant, and leaving it behind would be a second source
            // of truth that drifts.
            clearLegacyProfiles()
            migrationPending = false
            isLoaded = true

        case .noFile:
            if let legacy = loadLegacyProfiles() {
                do {
                    try await storage.save(legacy)
                    apply(legacy)
                    clearLegacyProfiles()
                    migrationPending = false
                    isLoaded = true
                    Logger.info(
                        "ProviderProfileStore: migrated \(legacy.profiles.count) profile(s) into the data folder"
                    )
                } catch {
                    // The folder is not writable right now. Keep working
                    // from the legacy copy and retry the migration later.
                    apply(legacy)
                    migrationPending = true
                    isLoaded = true
                    Logger.error(
                        "ProviderProfileStore: migration to the data folder failed: \(error.localizedDescription)"
                    )
                }
            } else {
                // Nothing in the folder and nothing legacy: a genuine
                // first run.
                isLoaded = true
            }

        case .corrupted(let error):
            Logger.error(
                "ProviderProfileStore: profiles file unreadable: \(error.localizedDescription)"
            )
            if let legacy = loadLegacyProfiles() {
                // The legacy copy is a better answer than nothing.
                apply(legacy)
            } else {
                // The configuration is unrecoverable. Say so, rather than
                // showing an empty provider list as if the user had
                // never configured anything.
                needsProviderSetup = true
                defaults.set(true, forKey: Keys.needsSetup)
            }
            isLoaded = true
        }
    }

    private func apply(_ payload: ProviderProfileStorage.Payload) {
        profiles = payload.profiles
        activeProfileId = payload.activeProfileId
        // If the stored active id points at a profile that no longer
        // exists, clear it so the UI doesn't display a phantom.
        if let id = activeProfileId, !profiles.contains(where: { $0.id == id }) {
            activeProfileId = nil
        }
    }

    // MARK: - CRUD

    /// Inserts (or replaces, if `profile.id` already exists) a profile.
    /// `apiKey` is written to Keychain when non-nil and non-empty; pass nil
    /// for profiles where `requiresAPIKey == false`, or to leave an existing
    /// key untouched on update.
    func upsert(_ profile: LLMProviderProfile, apiKey: String?) async throws {
        var next = profiles
        if let idx = next.firstIndex(where: { $0.id == profile.id }) {
            next[idx] = profile
        } else {
            next.append(profile)
        }

        if let apiKey, !apiKey.isEmpty {
            try keychain.set(apiKey, account: profile.id.uuidString)
        }

        // First-ever profile is auto-activated so the LLM path actually works
        // without forcing the user to tap "set active" before they can record.
        var nextActive = activeProfileId ?? profile.id

        // The write is the commit point: the in-memory state is only
        // updated once the file has it, so a failed write cannot leave
        // the session showing a profile the folder does not have.
        try await storage.save(
            ProviderProfileStorage.Payload(profiles: next, activeProfileId: nextActive)
        )
        profiles = next
        activeProfileId = nextActive

        // Successful write counts as setup done.
        if needsProviderSetup {
            needsProviderSetup = false
            defaults.set(false, forKey: Keys.needsSetup)
        }
    }

    /// Deletes the profile + its Keychain entry. If it was active, clears
    /// `activeProfileId` (the Settings UI should disable the optimize toggle
    /// in response — see `LLMOptimizationGate`).
    func delete(_ id: UUID) async throws {
        let next = profiles.filter { $0.id != id }
        let nextActive = (activeProfileId == id) ? nil : activeProfileId
        try? keychain.delete(account: id.uuidString)
        try await storage.save(
            ProviderProfileStorage.Payload(profiles: next, activeProfileId: nextActive)
        )
        profiles = next
        activeProfileId = nextActive
    }

    // MARK: - Active

    func setActive(_ id: UUID?) async throws {
        if let id, !profiles.contains(where: { $0.id == id }) {
            // Setting a non-existent profile as active is a programmer error.
            return
        }
        try await storage.save(
            ProviderProfileStorage.Payload(profiles: profiles, activeProfileId: id)
        )
        activeProfileId = id
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
            defaults.set(true, forKey: Keys.needsSetup)
            Logger.info("ProviderProfileStore: legacy audioNote:llmToken cleared, needsProviderSetup=true")
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

    // MARK: - Legacy copy (migration source only)

    /// The profiles as they were stored in `UserDefaults`, before they
    /// moved into the data folder.
    private func loadLegacyProfiles() -> ProviderProfileStorage.Payload? {
        guard let data = defaults.data(forKey: Keys.profiles) else { return nil }
        guard let legacy = try? JSONDecoder().decode([LLMProviderProfile].self, from: data),
              !legacy.isEmpty else { return nil }
        let activeId = defaults.string(forKey: Keys.activeId).flatMap(UUID.init(uuidString:))
        return ProviderProfileStorage.Payload(profiles: legacy, activeProfileId: activeId)
    }

    private func clearLegacyProfiles() {
        defaults.removeObject(forKey: Keys.profiles)
        defaults.removeObject(forKey: Keys.activeId)
    }
}

// MARK: - Related-notes profile source

extension ProviderProfileStore: RelatedNotesProfileSource {
    /// The related-notes service reads the profile through this protocol.
    /// The load is awaited here rather than at the read site, because the
    /// profiles live in the data folder now and the read is asynchronous.
    func prepare() async {
        await ensureLoaded()
    }

    @MainActor
    func activeProfile() -> LLMProviderProfile? { active }
}
