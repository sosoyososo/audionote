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
    
    private let fileName = "transcriptions.json"
    
    private var fileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(fileName)
    }
    
    private init() {}
    
    func loadAll() throws -> [TranscriptionRecord] {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let records = try JSONDecoder().decode([TranscriptionRecord].self, from: data)
            return records.sorted { $0.createdAt > $1.createdAt }
        } catch {
            throw StorageError.decodingFailed
        }
    }
    
    func save(_ record: TranscriptionRecord) throws {
        var records = (try? loadAll()) ?? []
        
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        
        try saveAll(records)
    }
    
    func delete(id: UUID) throws {
        var records = try loadAll()
        records.removeAll { $0.id == id }
        try saveAll(records)
    }
    
    func get(id: UUID) throws -> TranscriptionRecord? {
        let records = try loadAll()
        return records.first { $0.id == id }
    }
    
    private func saveAll(_ records: [TranscriptionRecord]) throws {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StorageError.writeFailed(error)
        }
    }
}
