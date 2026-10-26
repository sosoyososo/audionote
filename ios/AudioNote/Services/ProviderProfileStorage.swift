import Foundation

/// The LLM provider profiles file, in the user's data folder.
///
/// **Why this is a file and not `UserDefaults`.** A profile's `id` is the
/// Keychain *account* its API key is stored under. `UserDefaults` dies
/// with the app, so after a reinstall the profiles were gone while their
/// API keys were still sitting in the Keychain, orphaned — the user had
/// to re-type the key. Keeping the profiles in the data folder means the
/// ids come back with the folder, and the keys are found again.
///
/// The API key itself stays in the Keychain and does **not** come here.
/// The folder is the user's, and it syncs, gets copied to a computer and
/// gets shared; a secret in it is a leak.
///
/// See `docs/decisions/0008-provider-profiles-in-the-data-folder.md`.
actor ProviderProfileStorage {
    static let shared = ProviderProfileStorage()

    /// What the file holds.
    ///
    /// The envelope exists so a future field can be added without
    /// changing the file's shape. `activeProfileId` lives here rather
    /// than in `UserDefaults` for the same reason the profiles do: it is
    /// part of the configuration, and it has to survive a reinstall.
    struct Payload: Codable, Equatable {
        var profiles: [LLMProviderProfile]
        var activeProfileId: UUID?

        init(profiles: [LLMProviderProfile], activeProfileId: UUID?) {
            self.profiles = profiles
            self.activeProfileId = activeProfileId
        }
    }

    /// The outcome of reading the profiles file.
    ///
    /// Same distinction `TranscriptionStorage.LoadOutcome` makes, for
    /// the same reason: "no file yet" is a normal first-run state, while
    /// "the file is there and cannot be parsed" is a failure the user
    /// has to be told about. Collapsing them into "no profiles" would
    /// make a damaged file look like a fresh install — and the user
    /// would re-type their API key for nothing.
    enum LoadOutcome {
        /// `profiles.json` does not exist. Either nothing was ever
        /// configured, or the app has not migrated yet.
        case noFile
        /// The file exists and parsed.
        case payload(Payload)
        /// The file exists but could not be read or decoded.
        case corrupted(Error)
    }

    /// Test seam. When set, every read and write goes to this exact file
    /// URL instead of the user-picked folder. Mirrors the seam
    /// `TranscriptionStorage` already has, for the same reason: the
    /// storage layer is where data is won and lost, so it is the layer
    /// that most needs to be testable.
    private let fileURLOverride: URL?

    /// Resolve the file URL via the main-actor `StorageCoordinator`. Hop
    /// to main, then return the cached URL. Returns `nil` when storage
    /// has not been bootstrapped yet — first launch, before the user
    /// picks a folder. Callers treat `nil` as "no profiles yet".
    private func fileURLOrNil() async -> URL? {
        if let fileURLOverride { return fileURLOverride }
        return await MainActor.run {
            StorageCoordinator.shared.isReady
                ? StorageCoordinator.shared.providerProfilesURL
                : nil
        }
    }

    private init() {
        fileURLOverride = nil
    }

    /// Test seam — see `fileURLOverride`.
    init(fileURL: URL) {
        fileURLOverride = fileURL
    }

    // MARK: - Read

    func loadOutcome() async -> LoadOutcome {
        guard let url = await fileURLOrNil() else { return .noFile }
        guard FileManager.default.fileExists(atPath: url.path) else { return .noFile }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return .payload(payload)
        } catch {
            return .corrupted(error)
        }
    }

    /// The profiles, or `nil` when the file is absent or damaged.
    ///
    /// The damaged case is deliberately `nil` rather than an empty
    /// payload: the caller has to be able to tell "nothing configured"
    /// from "something broke", because only the second one is worth
    /// telling the user about.
    func load() async -> Payload? {
        if case .payload(let payload) = await loadOutcome() {
            return payload
        }
        return nil
    }

    // MARK: - Write

    func save(_ payload: Payload) async throws {
        guard let url = await fileURLOrNil() else {
            throw StorageError.writeFailed(
                NSError(domain: "ProviderProfileStorage", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Storage not bootstrapped"])
            )
        }
        do {
            let data = try JSONEncoder().encode(payload)
            // `.atomic`: the rewrite either lands whole or not at all.
            try data.write(to: url, options: .atomic)
        } catch {
            throw StorageError.writeFailed(error)
        }
    }
}
