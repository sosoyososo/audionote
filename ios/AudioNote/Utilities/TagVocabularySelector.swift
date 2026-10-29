import Foundation

/// Picks the tags worth showing the model when a note is tagged.
///
/// The vocabulary used to be "the 30 most-used tags", and that selection is
/// self-reinforcing: a tag used once is ranked last, so it is never offered,
/// so the model never reuses it, so it stays used once. The tags that bloat a
/// library live in exactly that tail — which is why a library of 43 notes can
/// carry 158 tags and the prompt's "reuse an existing spelling" instruction
/// still does not stop it.
///
/// So relevance comes first and frequency only breaks ties and fills the rest:
/// tags that occur in this note's own text are offered before the general
/// head of the distribution. The list stays short — the prompt's vocabulary
/// competes with the transcript for the model's attention — but the note's own
/// topic is no longer excluded by how rare its wording happens to be.
///
/// "Relevant" here is **literal**: the tag occurs in the note, shares a
/// two-character CJK substring with it, or shares a word of three letters or
/// more. Semantic equivalence (`工作` / `工作项`) is a different job — that is
/// what the merge proposal on the tag list page is for.
enum TagVocabularySelector {

    /// - Parameters:
    ///   - counts: tag spelling → how often the library uses it. The whole
    ///     library, archived records included.
    ///   - text: the text the tags will be extracted from.
    ///   - limit: how many tags to return at most.
    /// - Returns: the tag spellings to hand to the model, most relevant first.
    static func select(counts: [String: Int], text: String, limit: Int) -> [String] {
        guard limit > 0, !counts.isEmpty else { return [] }

        let haystack = comparisonText(text)
        var relevant: [(key: String, value: Int)] = []
        var rest: [(key: String, value: Int)] = []

        for entry in counts.sorted(by: byFrequencyThenName) {
            if isRelevant(entry.key, haystack: haystack) {
                relevant.append(entry)
            } else {
                rest.append(entry)
            }
        }

        return (relevant + rest).prefix(limit).map(\.key)
    }

    // MARK: - Ordering

    /// Frequency first, then alphabetical. The same order the library used
    /// before relevance existed, so the "fill the rest" half of the selection
    /// is unchanged by this type.
    private static func byFrequencyThenName(
        _ lhs: (key: String, value: Int),
        _ rhs: (key: String, value: Int)
    ) -> Bool {
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
    }

    // MARK: - Relevance

    private static func isRelevant(_ tag: String, haystack: String) -> Bool {
        let needle = comparisonText(tag)
        guard !needle.isEmpty, !haystack.isEmpty else { return false }

        if containsCJK(needle) {
            // CJK has no word boundaries, so a substring is the closest thing
            // to a whole word. `会议纪要` is relevant to a note that says
            // 会议 even though the full tag is not in it.
            if haystack.contains(needle) { return true }
            return cjkBigrams(of: needle).contains(where: { haystack.contains($0) })
        }

        // Latin script does have word boundaries, and using them matters: a
        // two-letter tag like `ai` occurs inside `daily`, and treating that as
        // relevant would offer the tag to every note that mentions a daily
        // routine. So the tag must appear as a whole word — or share a word
        // of three letters or more, which covers `work` against `work items`.
        let tagWords = words(of: needle)
        let textWords = words(of: haystack)
        if containsSequence(tagWords, in: textWords) { return true }
        return Set(tagWords).intersection(Set(textWords)).contains { $0.count >= 3 }
    }

    private static func containsSequence(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.contains(where: isCJK)
    }

    /// Lower-cased and trimmed, for comparison only. The spelling handed to
    /// the model is never changed — folding case here would hide from the
    /// model the very spelling drift it is being asked to fix.
    private static func comparisonText(_ text: String) -> String {
        TagIdentity.normalized(text).lowercased()
    }

    /// The runs of letters and digits in a piece of text. No length filter:
    /// the caller decides what counts as a meaningful shared word.
    private static func words(of text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func cjkBigrams(of text: String) -> [String] {
        let characters = Array(text)
        guard characters.count >= 2 else { return [] }
        return (0..<(characters.count - 1)).map { index -> String in
            let pair = characters[index...index + 1]
            guard pair.allSatisfy(isCJK) else { return "" }
            return String(pair)
        }.filter { !$0.isEmpty }
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)      // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(value)      // Extension A
            || (0xF900...0xFAFF).contains(value)      // Compatibility Ideographs
    }
}
