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
/// Deliberately *not* normalized any further — `" Work"` and `"Work"` are the
/// same unreported problem with a different cause, and trimming here would
/// change stored tag display for reasons outside this fix.
enum TagIdentity {

    /// The comparison key for a tag name. This is also the shape `Set`
    /// membership should use when testing many tags at once.
    static func key(_ name: String) -> String {
        name.lowercased()
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
