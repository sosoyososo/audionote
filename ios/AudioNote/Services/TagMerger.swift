import Foundation

/// Folds near-synonym tags into one, library-wide.
///
/// The prompt asks the LLM to reuse existing tag names, but the drift is
/// already on disk: `工作`, `工作项` and `工作会议` are three chips, each
/// filtering only to its own records. Merging them is a manual, deliberate
/// act — the user long-presses the tag that survives and ticks the ones
/// that disappear into it (spec §Decision).
///
/// Pure and I/O-free so the semantics are testable without a storage seam,
/// the same reason `PendingRecognitionPolicy` is pure statics. The single
/// write is `TranscriptionStorage.mergeTags`.
enum TagMerger {

    /// Rewrites `records` so every tag matching one of `sources` — or the
    /// target itself — collapses into a single `target` tag per record.
    ///
    /// Records carrying no match are returned **unchanged**. Records with
    /// `tags == nil` keep it that way: this is a rewrite, not a chance to
    /// introduce empty arrays the rest of the app would then have to treat
    /// as "has tags".
    static func merge(
        records: [TranscriptionRecord],
        into target: String,
        from sources: [String]
    ) -> [TranscriptionRecord] {
        guard !sources.isEmpty else { return records }

        // The target's own identity is part of the hit set, not an accident
        // of the union. A record already tagged `工作` (0.4) that also has
        // `工作项` (0.9) must end up as ONE `工作` at 0.9. Without the target
        // in the set, that record's existing `工作` would be left alone and
        // a second `工作` would be inserted beside it.
        let targetKey = TagIdentity.key(target)
        var hitKeys = TagIdentity.matchingKeys(Set(sources))
        hitKeys.insert(targetKey)

        return records.map { record in
            guard let tags = record.tags, !tags.isEmpty else { return record }

            let hitIndices = tags.indices.filter { hitKeys.contains(TagIdentity.key(tags[$0].name)) }
            guard !hitIndices.isEmpty else { return record }

            let hitScores = hitIndices.map { tags[$0].score }
            let merged = TaggedItem(name: target, score: hitScores.max()!)
            let firstHit = hitIndices[0]
            let isHit = Set(hitIndices)

            var rewritten: [TaggedItem] = []
            rewritten.reserveCapacity(tags.count - hitIndices.count + 1)
            for index in tags.indices {
                if index == firstHit {
                    rewritten.append(merged)
                }
                if !isHit.contains(index) {
                    rewritten.append(tags[index])
                }
            }

            var updated = record
            updated.tags = rewritten
            return updated
        }
    }

    /// The filter selection a merge implies: any selected source becomes the
    /// target, everything else is untouched.
    ///
    /// This exists as a pure function, and is called from the view model,
    /// because that is the only way it can be tested. `TranscriptionViewModel`
    /// holds `storage` as a `private let` singleton, so any VM method that
    /// touches disk cannot be unit-tested — see spec §3 for the failure it
    /// prevents, and `PendingRecognitionPolicy` for the same precedent.
    ///
    /// Two entries can collapse into one here, and that is correct: they were
    /// selected under different spellings of the tag now being merged, so
    /// their filters were already equivalent.
    static func remappedSelection(
        _ selected: Set<String>,
        into target: String,
        from sources: [String]
    ) -> Set<String> {
        guard !sources.isEmpty else { return selected }

        let sourceKeys = TagIdentity.matchingKeys(Set(sources))
        return Set(selected.map { entry in
            sourceKeys.contains(TagIdentity.key(entry)) ? target : entry
        })
    }
}
