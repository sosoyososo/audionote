import Foundation

actor AIProcessingService {
    private let llmService = LLMService()
    private let storage = TranscriptionStorage.shared

    func processRecord(_ record: TranscriptionRecord) async -> TranscriptionRecord {
        let token = UserDefaults.standard.string(forKey: "audioNote:llmToken") ?? ""

        var updatedRecord = record
        updatedRecord.llmProcessingStatus = .processing

        do {
            let result = try await llmService.process(record.content, token: token)
            updatedRecord.title = result.title
            updatedRecord.summary = result.summary
            updatedRecord.tags = result.tags
            updatedRecord.llmProcessingStatus = .completed
        } catch {
            Logger.error("LLM processing failed for record \(record.id): \(error.localizedDescription)")
            updatedRecord.llmProcessingStatus = .failed
        }

        do {
            try await storage.save(updatedRecord)
        } catch {
            Logger.error("Failed to save processed record: \(error.localizedDescription)")
        }
        return updatedRecord
    }

    /// Process records that have never been processed (llmProcessingStatus == nil)
    /// Records with .failed status are NOT auto-processed to avoid infinite loops
    func processPendingRecords() async {
        do {
            let records = try await storage.loadAll()
            // Only process records with nil status (never processed)
            // Do NOT auto-process .failed records to avoid infinite retry loops
            let pendingRecords = records.filter { $0.llmProcessingStatus == nil }

            for record in pendingRecords {
                _ = await processRecord(record)
            }
        } catch {
            Logger.error("Failed to load records for processing: \(error.localizedDescription)")
        }
    }
}
