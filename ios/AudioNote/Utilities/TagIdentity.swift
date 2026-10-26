import Foundation

/// The single place tag names are compared for equality.
///
/// Tags are produced by an LLM that picks its own casing per record, so a
/// library ends up carrying both `Work` and `work`. Under case-sensitive
/// comparison each spelling gets its own chip, and each chip then filters only
/// to records spelled that way — the tag looks present in the row and matches
/// nothing in the list. Identity is therefore case-insensitive, and the
/// chip-building side picks one display form per identity
/// (`TranscriptionViewModel.availableTags`).
///
/// CJK has no case, so `lowercased()` is a no-op for it: a Chinese-only library
/// behaves exactly as before. Only Latin-script tags are affected.
///
/// Two axes, deliberately separate. **Case** folds in `key` (the comparison)
/// but not in `normalized` (the display form) — a chip shows one spelling for
/// an identity, and which spelling is a separate, deliberately-visible
/// decision. **Whitespace** folds in both, because leading/trailing spaces are
/// never intentional in a tag and are invisible on screen; folding them in
/// `key` also keeps identity whitespace-insensitive for a record written
/// before `TaggedItem` started trimming on decode.
enum TagIdentity {

    /// The canonical stored form of a tag name: whitespace trimmed.
    ///
    /// `TaggedItem.init(from:)` already applies this to everything decoded —
    /// LLM results and on-disk records alike — so this exists for values built
    /// in memory without a decode round-trip, and to name the invariant in one
    /// place rather than repeating `trimmingCharacters` at each call site.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The comparison key for a tag name. This is also the shape `Set`
    /// membership should use when testing many tags at once.
    static func key(_ name: String) -> String {
        normalized(name).lowercased()
    }

    /// Lowercases a whole selection once, so a filter loop tests membership
    /// against a prepared set instead of re-lowercasing the selection per tag.
    static func matchingKeys(_ names: Set<String>) -> Set<String> {
        Set(names.map(key))
    }

    /// Whether `name` is in `selected`, ignoring case.
    static func matches(_ name: String, anyOf selected: Set<String>) -> Bool {
        selected.contains { key($0) == key(name) }
    }

    /// How many of a record's tags fall under any of `selectedKeys`, counting
    /// each identity once: a record carrying both `Work` and `work` matches the
    /// merged chip once, not twice. Used as the tag-rank sort key, where
    /// double-counting would rank such a record above one that genuinely
    /// matches two distinct filters.
    static func matchCount(ofNames names: [String], in selectedKeys: Set<String>) -> Int {
        guard !selectedKeys.isEmpty else { return 0 }
        return Set(names.map(key)).intersection(selectedKeys).count
    }

    /// The names in `candidates` that match `selectedKeys`, keeping each
    /// candidate's own spelling. Returns the *candidate's* spelling rather
    /// than the filter's, because callers read the result back as tags on that
    /// record (its own scores, its own display).
    static func matching(_ candidates: [String], in selectedKeys: Set<String>) -> [String] {
        guard !selectedKeys.isEmpty else { return [] }
        return candidates.filter { selectedKeys.contains(key($0)) }
    }
}

extension TagIdentity {
    /// Whether a tag matches what the user typed.
    ///
    /// Case-insensitive substring, not prefix: "议" should find "会议记录",
    /// and a Chinese user searching by the middle of a word is the normal
    /// way to type. An empty query matches everything, so the caller does
    /// not need a special case.
    static func contains(_ tag: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return tag.localizedCaseInsensitiveContains(trimmed)
    }
}
