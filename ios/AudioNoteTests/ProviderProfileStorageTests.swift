import XCTest
@testable import AudioNote

/// Tests for the provider-profile file in the data folder, and for the
/// one-shot migration that moved the profiles out of `UserDefaults`.
///
/// The migration is the delicate part. A profile's `id` is the Keychain
/// *account* its API key is stored under, so a migration that changed an
/// id would orphan the key and force the user to re-type it — the exact
/// outcome the move was meant to prevent.
final class ProviderProfileStorageTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderProfileStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("profiles.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func profile(
        id: UUID = UUID(),
        name: String = "DeepSeek",
        requiresAPIKey: Bool = true
    ) -> LLMProviderProfile {
        LLMProviderProfile(
            id: id,
            displayName: name,
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            model: "deepseek-chat",
            requiresAPIKey: requiresAPIKey
        )
    }

    // MARK: - The file

    func testAMissingFileIsReportedAsNoFile() async throws {
        let storage = ProviderProfileStorage(fileURL: fileURL)
        switch await storage.loadOutcome() {
        case .noFile:
            break
        case .payload(let payload):
            XCTFail("expected .noFile, got \(payload.profiles.count) profile(s)")
        case .corrupted:
            XCTFail("expected .noFile, got .corrupted")
        }
    }

    func testThePayloadRoundTrips() async throws {
        let storage = ProviderProfileStorage(fileURL: fileURL)
        let original = profile()
        let payload = ProviderProfileStorage.Payload(
            profiles: [original],
            activeProfileId: original.id
        )
        try await storage.save(payload)

        switch await storage.loadOutcome() {
        case .payload(let loaded):
            XCTAssertEqual(loaded.profiles.map(\.id), [original.id])
            XCTAssertEqual(loaded.activeProfileId, original.id)
            XCTAssertEqual(loaded.profiles.first?.displayName, "DeepSeek")
        case .noFile:
            XCTFail("expected .payload, got .noFile")
        case .corrupted:
            XCTFail("expected .payload, got .corrupted")
        }
    }

    /// A damaged file must not look like a fresh install. If it did, the
    /// user would be told they had never configured a provider — while
    /// their API key sat in the Keychain under an id nothing pointed at
    /// any more.
    func testACorruptFileIsReportedAsCorruptedRatherThanEmpty() async throws {
        try Data("{ this is not json".utf8).write(to: fileURL)
        let storage = ProviderProfileStorage(fileURL: fileURL)
        switch await storage.loadOutcome() {
        case .corrupted:
            break
        case .noFile:
            XCTFail("expected .corrupted, got .noFile")
        case .payload(let payload):
            XCTFail("expected .corrupted, got a payload with \(payload.profiles.count) profile(s)")
        }
    }

    /// `load()` is the convenience read, and it must not turn a damaged
    /// file into an empty configuration.
    func testTheConvenienceReadDoesNotSwallowACorruptFile() async throws {
        try Data("not json at all".utf8).write(to: fileURL)
        let storage = ProviderProfileStorage(fileURL: fileURL)
        let payload = await storage.load()
        XCTAssertNil(payload, "a corrupt file must not read as an empty configuration")
    }
}

/// Tests for `ProviderProfileStore`'s migration and persistence.
@MainActor
final class ProviderProfileStoreTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var keychain: KeychainStore!

    /// The `UserDefaults` key the profiles lived under before they moved
    /// into the data folder.
    ///
    /// Hard-coded on purpose: this key is the contract with the builds
    /// that came before the move. Renaming it would strand every existing
    /// user's configuration — and their API keys with it.
    private let legacyProfilesKey = "audioNote:llmProfiles"
    private let legacyActiveIdKey = "audioNote:activeLLMProfileId"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderProfileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("profiles.json")
        defaultsSuiteName = "ProviderProfileStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        keychain = KeychainStore(service: "audioNote.llm.tests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try super.tearDownWithError()
    }

    private func makeStore() -> ProviderProfileStore {
        ProviderProfileStore(
            defaults: defaults,
            keychain: keychain,
            storage: ProviderProfileStorage(fileURL: fileURL)
        )
    }

    private func seedLegacyProfiles(_ profiles: [LLMProviderProfile], activeId: UUID?) {
        let data = try! JSONEncoder().encode(profiles)
        defaults.set(data, forKey: legacyProfilesKey)
        if let activeId {
            defaults.set(activeId.uuidString, forKey: legacyActiveIdKey)
        }
    }

    // MARK: - The migration

    /// The whole point of the move. The ids have to survive it, because
    /// the ids are the Keychain accounts the API keys are stored under.
    func testTheMigrationPreservesTheProfileIds() async throws {
        let original = LLMProviderProfile(
            id: UUID(),
            displayName: "My DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            model: "deepseek-chat"
        )
        seedLegacyProfiles([original], activeId: original.id)

        let store = makeStore()
        await store.ensureLoaded()

        XCTAssertEqual(store.profiles.map(\.id), [original.id])
        XCTAssertEqual(store.activeProfileId, original.id)
        XCTAssertEqual(store.active?.displayName, "My DeepSeek")

        // And the ids have to be in the file, not just in memory.
        let stored = await ProviderProfileStorage(fileURL: fileURL).load()
        XCTAssertEqual(stored?.profiles.map(\.id), [original.id])
        XCTAssertEqual(stored?.activeProfileId, original.id)
    }

    /// The migrated profile's API key has to still be findable under the
    /// id it had before the move. This is the test that would catch a
    /// migration that regenerated ids.
    func testTheApiKeyIsStillFindableUnderTheMigratedId() async throws {
        let original = LLMProviderProfile(
            id: UUID(),
            displayName: "My DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            model: "deepseek-chat"
        )
        try keychain.set("sk-secret", account: original.id.uuidString)
        defer { try? keychain.delete(account: original.id.uuidString) }
        seedLegacyProfiles([original], activeId: original.id)

        let store = makeStore()
        await store.ensureLoaded()

        // Look the key up **through the migrated profile**, not through
        // the id it used to have. Asking for the old id directly would
        // find the key even if the migration had thrown the id away —
        // which is exactly the bug this test exists to catch.
        let migratedId = try XCTUnwrap(store.profiles.first?.id)
        XCTAssertEqual(migratedId, original.id, "the migration must not change the id")
        XCTAssertEqual(store.apiKey(for: migratedId), "sk-secret")
    }

    func testTheMigrationClearsTheLegacyCopy() async throws {
        let original = LLMProviderProfile(
            id: UUID(),
            displayName: "My DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            model: "deepseek-chat"
        )
        seedLegacyProfiles([original], activeId: original.id)

        let store = makeStore()
        await store.ensureLoaded()

        // The folder is the source of truth now. A leftover copy in
        // UserDefaults would be a second source of truth, and it would
        // go stale.
        XCTAssertNil(defaults.data(forKey: legacyProfilesKey))
        XCTAssertNil(defaults.string(forKey: legacyActiveIdKey))
    }

    /// The folder wins over the legacy copy. A user who had already
    /// migrated once must not have their folder copy overwritten by a
    /// stale `UserDefaults` copy.
    func testTheFolderIsNotOverwrittenByALegacyCopy() async throws {
        let folderProfile = LLMProviderProfile(
            id: UUID(),
            displayName: "From the folder",
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            model: "deepseek-chat"
        )
        let legacyProfile = LLMProviderProfile(
            id: UUID(),
            displayName: "From UserDefaults",
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            model: "deepseek-chat"
        )
        try await ProviderProfileStorage(fileURL: fileURL).save(
            ProviderProfileStorage.Payload(profiles: [folderProfile], activeProfileId: folderProfile.id)
        )
        seedLegacyProfiles([legacyProfile], activeId: legacyProfile.id)

        let store = makeStore()
        await store.ensureLoaded()

        XCTAssertEqual(store.profiles.map(\.id), [folderProfile.id])
    }

    /// Nothing in the folder and nothing legacy: a genuine first run.
    /// The store must report "loaded" so the settings screen stops
    /// showing its loading placeholder.
    func testAFirstRunEndsUpLoadedAndEmpty() async throws {
        let store = makeStore()
        await store.ensureLoaded()
        XCTAssertTrue(store.isLoaded)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.active)
    }

    // MARK: - Persistence

    func testUpsertWritesToTheFile() async throws {
        let store = makeStore()
        await store.ensureLoaded()
        let newProfile = LLMProviderProfile(
            id: UUID(),
            displayName: "My DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            model: "deepseek-chat"
        )
        try await store.upsert(newProfile, apiKey: "sk-test")

        let stored = await ProviderProfileStorage(fileURL: fileURL).load()
        XCTAssertEqual(stored?.profiles.map(\.id), [newProfile.id])
        // The first profile is activated automatically, so the LLM path
        // works without the user tapping "set active".
        XCTAssertEqual(stored?.activeProfileId, newProfile.id)
        XCTAssertEqual(store.apiKey(for: newProfile.id), "sk-test")
        try? keychain.delete(account: newProfile.id.uuidString)
    }

    func testDeleteRemovesTheProfileFromTheFile() async throws {
        let store = makeStore()
        await store.ensureLoaded()
        let keep = LLMProviderProfile(
            id: UUID(), displayName: "Keep",
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!, model: "m"
        )
        let drop = LLMProviderProfile(
            id: UUID(), displayName: "Drop",
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!, model: "m"
        )
        try await store.upsert(keep, apiKey: nil)
        try await store.upsert(drop, apiKey: nil)
        try await store.delete(drop.id)

        let stored = await ProviderProfileStorage(fileURL: fileURL).load()
        XCTAssertEqual(stored?.profiles.map(\.id), [keep.id])
        XCTAssertFalse(store.profiles.contains { $0.id == drop.id })
    }

    func testSetActiveIsPersisted() async throws {
        let store = makeStore()
        await store.ensureLoaded()
        let first = LLMProviderProfile(
            id: UUID(), displayName: "First",
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!, model: "m"
        )
        let second = LLMProviderProfile(
            id: UUID(), displayName: "Second",
            baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!, model: "m"
        )
        try await store.upsert(first, apiKey: nil)
        try await store.upsert(second, apiKey: nil)
        try await store.setActive(second.id)

        let stored = await ProviderProfileStorage(fileURL: fileURL).load()
        XCTAssertEqual(stored?.activeProfileId, second.id)
        XCTAssertEqual(store.active?.id, second.id)
    }
}
