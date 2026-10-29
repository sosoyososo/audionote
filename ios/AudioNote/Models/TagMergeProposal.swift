import Foundation

/// One group in a merge request: the tag everything collapses into, and
/// the tags that collapse into it.
struct TagMergeGroup: Equatable {
    let target: String
    let sources: [String]
}

/// What a batch merge actually did.
///
/// `applied` lists the groups that were carried out — not the ones that
/// were asked for. The difference matters: the caller remaps the current
/// tag selection from the groups that landed, and pointing it at a group
/// that was skipped would select a tag that was never merged.
struct TagMergeOutcome: Equatable {
    let applied: [TagMergeGroup]
    let skipped: Int
    let affectedNotes: Int

    static let empty = TagMergeOutcome(applied: [], skipped: 0, affectedNotes: 0)
}

/// One group of tags the model believes mean the same thing, and the name
/// they should collapse into.
///
/// **A proposal, not an action.** The model may only suggest; the merge
/// happens when the user says so, and the user may prune the proposal list
/// first. See ADR-0010.
struct TagMergeProposal: Identifiable, Equatable {
    let id: UUID

    /// The tag the group collapses into. Always a tag the library already
    /// has — a merge does not create vocabulary.
    var target: String

    /// The tags that collapse into `target`. Never contains `target` itself.
    var sources: [String]

    /// How many notes carry each of these tags. Display only — it tells the
    /// user what a merge would cost, and it is not part of the merge.
    var counts: [String: Int]

    init(
        id: UUID = UUID(),
        target: String,
        sources: [String],
        counts: [String: Int] = [:]
    ) {
        self.id = id
        self.target = target
        self.sources = sources
        self.counts = counts
    }

    /// The notes this proposal would touch, by identity. A note carrying
    /// two of the tags counts once — it is rewritten once.
    ///
    /// Deliberately not the sum of `counts`: two tags on one note are one
    /// note to rewrite, and a number that says otherwise misleads the user
    /// about what agreeing to it costs.
    func affectedNoteCount(in records: [TranscriptionRecord]) -> Int {
        let sourceKeys = Set(sources.map(TagIdentity.key))
        guard !sourceKeys.isEmpty else { return 0 }
        return records.filter { record in
            record.tagNames.contains { sourceKeys.contains(TagIdentity.key($0)) }
        }.count
    }
}
