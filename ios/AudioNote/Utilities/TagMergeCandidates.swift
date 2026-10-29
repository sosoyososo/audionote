import Foundation

/// The tags worth asking the model about, grouped by what they have in
/// common.
///
/// The whole vocabulary is the wrong thing to send. The model reasons out
/// loud — measured at 29,813 characters for one answer — and most of that
/// was spent ruling out tags that obviously did not belong together. Sending
/// only the groups that already look alike leaves it with nothing to rule
/// out, and the answer comes back denser.
///
/// **Grouping is by a shared substring, and it is deliberately not
/// transitive.** Linking tags transitively chains everything: `功能` shares
/// with `反馈`, `反馈` with `用户`, `用户` with `产品`, and a single-link
/// clustering puts seventy tags in one group. A group here is "these tags
/// all contain this particular substring", which keeps the groups small and
/// the reasoning honest.
///
/// A tag may appear in more than one group — `笔记相关度` belongs with
/// `笔记关联` (they share 笔记) and with `相关度计算` (they share 相关度),
/// and both of those are worth showing.
enum TagMergeCandidates {

    /// The groups of tags that might be the same thing.
    ///
    /// - Parameters:
    ///   - counts: tag spelling → how many notes carry it.
    ///   - headSize: how many of the most-used tags to include even when
    ///     nothing resembles them. The most-used tags are where reuse pays
    ///     off, and a pure synonym (会议 / 研讨) shares no characters with
    ///     anything — so without this they could never be found.
    ///   - maxGroups: how many groups to return at most.
    static func groups(
        counts: [String: Int],
        headSize: Int = 10,
        maxGroups: Int = 40
    ) -> [[String]] {
        guard !counts.isEmpty else { return [] }

        let byFrequency = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }

        var byKey: [String: [String]] = [:]
        for (tag, _) in byFrequency {
            for key in sharedKeys(of: tag) {
                byKey[key, default: []].append(tag)
            }
        }

        // The most-used tags go first, and on their own: they are where
        // reuse pays off, and a pure synonym (会议 / 研讨) shares no
        // characters with anything, so similarity alone would never surface
        // it. They must also survive the cap — appended last, they were the
        // first thing cut, and the model was left with nothing worth
        // merging.
        var groups: [[String]] = []
        let head = byFrequency.prefix(headSize).map(\.key)
        if head.count >= 2 {
            groups.append(head)
        }

        var seen = Set<Set<String>>()
        var rest: [[String]] = []
        // One group per shared substring or shared word. The groups are
        // built from the keys, not from pairs of tags, so nothing chains.
        for (_, members) in byKey {
            guard members.count >= 2 else { continue }
            let identity = Set(members.map(TagIdentity.key))
            guard seen.insert(identity).inserted else { continue }
            rest.append(members)
        }

        // Most-used group first, so the cap keeps the groups that matter.
        rest.sort { lhs, rhs in
            let lhsBest = lhs.map { counts[$0] ?? 0 }.max() ?? 0
            let rhsBest = rhs.map { counts[$0] ?? 0 }.max() ?? 0
            if lhsBest != rhsBest { return lhsBest > rhsBest }
            return lhs.sorted().lexicographicallyPrecedes(rhs.sorted())
        }

        groups.append(contentsOf: rest)
        return Array(groups.prefix(maxGroups))
    }

    /// The substrings two tags would have to share to be candidates.
    ///
    /// Two characters of Chinese, or a word of three letters or more. One
    /// character is too weak — `语` is in half the library — and a two-letter
    /// Latin word is too weak for the same reason: `ai` sits inside `daily`.
    static func sharedKeys(of tag: String) -> Set<String> {
        var keys = Set<String>()

        let characters = Array(tag)
        if characters.count >= 2 {
            for index in 0..<(characters.count - 1) {
                let pair = characters[index...index + 1]
                guard pair.allSatisfy(isCJK) else { continue }
                keys.insert(String(pair))
            }
        }

        for word in tag.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where word.count >= 3 {
            keys.insert(word.lowercased())
        }

        return keys
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }
}
