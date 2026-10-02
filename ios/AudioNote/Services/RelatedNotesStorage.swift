import Foundation

/// Persists "these two notes are related" edges to `relatedNotes.json`,
/// a sibling of `transcriptions.json` in the user's AudioNote folder.
///
/// Deliberately does **not** cache: the file is a few KB and re-reading it
/// per detail view is cheaper than the invalidation a cache would need.
///
/// Singleton reads through `StorageCoordinator`; the `fileURL` initializer
/// exists so unit tests can point it at a temp directory.
final class RelatedNotesStorage {

    /// Edges scoring below this are stored but never displayed. Sitting well
    /// inside the LLM's plausible output range keeps visibility from flipping
    /// on a knife-edge comparison.
    static let minimumScore: Double = 0.3

    static let shared = RelatedNotesStorage()

    private let fileURL: URL?

    private init() {
        fileURL = nil // resolved lazily per call via StorageCoordinator
    }

    /// Test seam. When set, all reads and writes go to this exact URL.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - URL resolution

    private func resolvedURL() async -> URL? {
        if let fileURL { return fileURL }
        return await MainActor.run {
            StorageCoordinator.shared.isReady
                ? StorageCoordinator.shared.relatedNotesURL
                : nil
        }
    }

    // MARK: - Reads

    func loadAll() async throws -> [NoteRelation] {
        guard let url = await resolvedURL() else { return [] }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([NoteRelation].self, from: data)
    }

    /// Counterpart notes for `id`, strongest first, threshold applied.
    func related(to id: UUID) async -> [RelatedNote] {
        guard let all = try? await loadAll() else { return [] }
        return all
            .compactMap { edge -> RelatedNote? in
                guard let other = edge.otherID(from: id),
                      edge.score >= Self.minimumScore else { return nil }
                return RelatedNote(id: other, score: edge.score)
            }
            .sorted { $0.score > $1.score }
    }

    // MARK: - Writes

    /// Merge `relations` into the stored set. An existing undirected pair has
    /// its score replaced rather than duplicated.
    func upsert(_ relations: [NoteRelation]) async throws {
        guard !relations.isEmpty else { return }
        // `uniquingKeysWith:` rather than `Dictionary(uniqueKeysWithValues:)`:
        // a hand-edited or partially-merged file can hold a duplicate pair,
        // and that must degrade, never trap.
        let existing = (try? await loadAll()) ?? []
        var merged = Dictionary(existing.map { ($0.key, $0) },
                                uniquingKeysWith: { existing, _ in existing })
        for relation in relations {
            merged[relation.key] = relation
        }
        try await saveAll(Array(merged.values))
    }

    /// Drop every edge touching `id`. Called when a note is deleted or archived.
    func removeAll(involving id: UUID) async throws {
        let all = try await loadAll()
        let kept = all.filter { !$0.involves(id) }
        guard kept.count != all.count else { return }
        try await saveAll(kept)
    }

    private func saveAll(_ relations: [NoteRelation]) async throws {
        guard let url = await resolvedURL() else {
            throw StorageError.writeFailed(
                NSError(domain: "RelatedNotesStorage", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Storage not bootstrapped"])
            )
        }
        let data = try JSONEncoder().encode(relations)
        try data.write(to: url, options: .atomic)
    }
}
