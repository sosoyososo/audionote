import Foundation

enum StorageError: LocalizedError {
    case fileNotFound
    case encodingFailed
    case decodingFailed
    case writeFailed(Error)
    case deleteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "文件不存在"
        case .encodingFailed:
            return "编码失败"
        case .decodingFailed:
            return "解码失败"
        case .writeFailed(let error):
            return "写入失败: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "删除失败: \(error.localizedDescription)"
        }
    }
}

actor TranscriptionStorage {
    static let shared = TranscriptionStorage()

    /// The outcome of reading the records file.
    ///
    /// The distinction that matters: a library that has never been written
    /// (`noFile`) is a normal empty state, while a file that exists but
    /// cannot be parsed (`corrupted`) is a failure the user has to be told
    /// about. Collapsing them into "no records" is how a corrupted
    /// library starts looking like a deleted one.
    enum LoadOutcome {
        /// `transcriptions.json` does not exist — nothing has been saved
        /// yet, or it was removed outside the app.
        case noFile
        /// The file exists and parsed.
        case records([TranscriptionRecord])
        /// The file exists but could not be read or decoded.
        case corrupted(Error)
    }

    /// Test seam. When set, every read and write goes to this exact file
    /// URL instead of the user-picked folder. Mirrors the seam
    /// `RelatedNotesStorage` already has, for the same reason: the
    /// storage layer is where data is won and lost, so it is the layer
    /// that most needs to be testable.
    private let fileURLOverride: URL?

    /// Resolve the JSON URL via the main-actor `StorageCoordinator`. Hop to
    /// main, then return the cached URL. Returns `nil` when storage has not
    /// been bootstrapped yet (first launch, before the user picks a folder
    /// via OnboardingView). Callers treat `nil` as "no records".
    private func jsonURLOrNil() async -> URL? {
        if let fileURLOverride { return fileURLOverride }
        return await MainActor.run {
            StorageCoordinator.shared.isReady
                ? StorageCoordinator.shared.jsonURL
                : nil
        }
    }

    private init() { fileURLOverride = nil }

    /// Test seam — see `fileURLOverride`.
    init(fileURL: URL) { fileURLOverride = fileURL }

    /// Read the records file, distinguishing "not there yet" from "there
    /// but broken".
    ///
    /// `loadAll()` (below) collapses both into an empty array or a thrown
    /// error. The view model needs the distinction, because a corrupted
    /// file rendered as an empty list is indistinguishable from a library
    /// the user never filled — and the user's reaction to the second is
    /// "where did my data go?", which is exactly the wrong conclusion.
    func loadOutcome() async -> LoadOutcome {
        guard let url = await jsonURLOrNil() else { return .noFile }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return .noFile }

        do {
            let data = try Data(contentsOf: url)
            let records = try JSONDecoder().decode([TranscriptionRecord].self, from: data)
            return .records(records.sorted { $0.createdAt > $1.createdAt })
        } catch {
            return .corrupted(error)
        }
    }

    func loadAll() async throws -> [TranscriptionRecord] {
        switch await loadOutcome() {
        case .noFile:
            return []
        case .records(let records):
            return records
        case .corrupted:
            // Preserved: the throwing contract is what every existing
            // caller relies on to tell "read failed" from "empty".
            throw StorageError.decodingFailed
        }
    }

    func save(_ record: TranscriptionRecord) async throws {
        // NOT `(try? await loadAll()) ?? []`.
        //
        // A read failure is not an empty library. Swallowing it here
        // meant that one corrupt file turned the next save into a
        // one-record file written over the whole library — total data
        // loss, with a symptom (an empty app) that looks exactly like the
        // user deleted everything themselves. The write must fail loudly
        // instead, so the library is left as it was and the user is told.
        var records = try await loadAll()

        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }

        try await saveAll(records)
    }

    func delete(id: UUID) async throws {
        var records = try await loadAll()
        records.removeAll { $0.id == id }
        try await saveAll(records)
    }

    /// Fold near-synonym tags into one across the **whole** library,
    /// archived records included. The rewrite itself is `TagMerger`'s, and
    /// is pure; this is the single write.
    ///
    /// Deliberately not a loop over `save(_:)`. `save` re-reads the entire
    /// file and re-encodes all of it on every call, so a merge touching 400
    /// records would be 400 full read-modify-write cycles — and a failure
    /// halfway through would leave a half-merged library that still parses
    /// and still looks intact. `saveAll` writes `.atomic`, so the rewrite
    /// either lands whole or not at all.
    func mergeTags(into target: String, from sources: [String]) async throws {
        guard !sources.isEmpty else { return }
        let records = try await loadAll()
        try await saveAll(TagMerger.merge(records: records, into: target, from: sources))
    }

    func get(id: UUID) async throws -> TranscriptionRecord? {
        guard await jsonURLOrNil() != nil else { return nil }
        let records = try await loadAll()
        return records.first { $0.id == id }
    }

    private func saveAll(_ records: [TranscriptionRecord]) async throws {
        guard let url = await jsonURLOrNil() else {
            throw StorageError.writeFailed(
                NSError(domain: "TranscriptionStorage", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Storage not bootstrapped"])
            )
        }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            throw StorageError.writeFailed(error)
        }
    }
}

// MARK: - Related notes

/// Satisfies `RecordsSource` for `RelatedNotesService.link(for:)`, which only
/// needs the read path. The actor-isolated `loadAll()` satisfies the async
/// requirement unchanged.
extension TranscriptionStorage: RecordsSource {}
