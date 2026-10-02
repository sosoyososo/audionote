import Foundation

/// One undirected "these two notes are related" edge.
///
/// `a` and `b` carry no directional meaning. The writer normalizes them so
/// that `a.uuidString <= b.uuidString`, which makes `(A,B)` and `(B,A)` the
/// same edge by construction — see `key`.
struct NoteRelation: Codable, Hashable {
    let a: UUID
    let b: UUID
    let score: Double

    init(a: UUID, b: UUID, score: Double) {
        // Normalize so key identity does not depend on argument order.
        if a.uuidString <= b.uuidString {
            self.a = a
            self.b = b
        } else {
            self.a = b
            self.b = a
        }
        self.score = score
    }

    /// Stable identity for the undirected pair.
    var key: String {
        min(a.uuidString, b.uuidString) + "|" + max(a.uuidString, b.uuidString)
    }

    func involves(_ id: UUID) -> Bool {
        a == id || b == id
    }

    /// The endpoint that is *not* `id`, or nil when `id` isn't on this edge.
    func otherID(from id: UUID) -> UUID? {
        if a == id { return b }
        if b == id { return a }
        return nil
    }
}

/// An edge resolved from one note's point of view: the *other* note's id
/// plus the pair's score. Produced by `RelatedNotesStorage.related(to:)` so
/// callers never deal with which side of the edge they hold.
struct RelatedNote: Identifiable, Hashable {
    let id: UUID
    let score: Double
}
