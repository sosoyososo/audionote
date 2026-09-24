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

    /// Resolve the JSON URL via the main-actor `StorageCoordinator`. Hop to
    /// main, then return the cached URL. Returns `nil` when storage has not
    /// been bootstrapped yet (first launch, before the user picks a folder
    /// via OnboardingView). Callers treat `nil` as "no records".
    private func jsonURLOrNil() async -> URL? {
        await MainActor.run {
            StorageCoordinator.shared.isReady
                ? StorageCoordinator.shared.jsonURL
                : nil
        }
    }

    private init() {}

    func loadAll() async throws -> [TranscriptionRecord] {
        guard let url = await jsonURLOrNil() else { return [] }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        do {
            let data = try Data(contentsOf: url)
            let records = try JSONDecoder().decode([TranscriptionRecord].self, from: data)
            return records.sorted { $0.createdAt > $1.createdAt }
        } catch {
            throw StorageError.decodingFailed
        }
    }

    func save(_ record: TranscriptionRecord) async throws {
        var records = (try? await loadAll()) ?? []

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