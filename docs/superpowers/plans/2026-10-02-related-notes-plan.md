# 相关思考 (Related Notes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a "相关思考" section at the bottom of a note's detail page listing the notes most related to it, computed by the LLM at write time and stored as undirected edges in a standalone `relatedNotes.json`.

**Architecture:** A new `RelatedNotesService` prescreens old notes locally (tag overlap → ≤20 candidates), asks the LLM which of those are actually related (one extra call, separate from `optimizeAndProcess`), and writes the result as undirected edges to `relatedNotes.json`. `TranscriptionRecord` gains no fields. The detail view reads edges for the current note and renders shared tags.

**Tech Stack:** Swift 5.9, SwiftUI (iOS 15.0+), `URLSession` for LLM calls, `Codable` + `JSONEncoder` for persistence, XCTest, XcodeGen 2.44.1, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-10-02-related-notes-design.md`

## Global Constraints

- Deployment target is **iOS 15.0**. No APIs newer than iOS 15 without a fallback.
- **Every online LLM call MUST be gated by `NetworkMonitor.shared.checkConnectivity()` first** (CLAUDE.md locked decision). No exceptions, including the new call in Task 5.
- `assessAndEnhance`'s three-case switch is **locked by ADR-0001** — do not add a case to it. Relation-linking hangs off `processWithLLM` instead.
- **`TranscriptionRecord` gains no new fields.** It already carries a legacy `[String]` → `[TaggedItem]` tags migration and `decodeIfPresent` fallbacks; this feature must not touch it.
- New user-facing strings go in **both** `ios/AudioNote/Resources/en.lproj/Localizable.strings` and `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings`. Key format: `"Section.Key" = "value";`
- `ios/AudioNote.xcodeproj` **is tracked in git**. After adding any new Swift file: run `xcodegen --spec project.yml` from `ios/` and commit the regenerated `project.pbxproj`.
- Relation data is **best-effort**: no error ever surfaces to the user, and a failure must never block or roll back a note's own save.

### Commands (run from `ios/` unless noted)

```sh
# Regenerate the Xcode project after adding files
xcodegen --spec project.yml

# Build — simulator
xcodebuild -scheme AudioNote -sdk iphonesimulator \
           -destination 'generic/platform=iOS Simulator' build

# Build — device (iPhone Air)
xcodebuild -scheme AudioNote \
           -destination 'platform=iOS,id=3C0B7BE4-2AEF-54E4-B937-9A0C96326420' build

# Run unit tests — iPhone Air simulator twin
xcodebuild test -scheme AudioNote \
           -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722'

# Install + launch on the real device
xcrun devicectl device install app \
           --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 <path/to/AudioNote.app>
xcrun devicectl device process launch \
           --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 info.karsa.app.ios.audionote
```

## Review Focus

Five input classes a reasonable user would exercise that the happy path won't cover. Each has a test pinned to the task that owns the code.

1. **The note has no `title` or `summary`** (LLM call 1 succeeded but returned empty strings, or the note is in a pre-upgrade JSON). The section must not crash and must not show a broken row. → Task 7 test.
2. **`relatedNotes.json` is corrupt on disk** (partial write from a crash, hand-edited). Decoding fails. The note's own content must still open normally — the failure is swallowed, section hidden. → Task 2 test.
3. **The LLM returns a UUID that isn't in the candidate set** — a hallucination or a stale id from a previous turn. It must be dropped, not written as a dangling edge. → Task 4 test.
4. **Two notes share the same tag but the other note is archived** — the prescreen must exclude it, and the render must skip it. A related row pointing at an archived note is a visible bug. → Task 3 and Task 7 tests.
5. **`score` is exactly on the `minimumScore` boundary** (0.3). `related(to:)` uses `>=`, so an edge at exactly the threshold is shown; one at 0.29 is hidden while still present in `loadAll()`. → Task 2 test.

---

### Task 0: Get a unit test running

The project has **zero existing tests** — `ios/AudioNoteTests/` is an empty directory. Every "this is a pure function, easy to test" claim below depends on the test target actually working. Establish that first.

**Files:**
- Create: `ios/AudioNoteTests/SmokeTests.swift`
- Verify: `ios/AudioNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing
- Produces: a working `AudioNoteTests` target; the test command in Global Constraints is proven to work

- [ ] **Step 1: Write the smoke test**

Create `ios/AudioNoteTests/SmokeTests.swift`:

```swift
import XCTest
@testable import AudioNote

final class SmokeTests: XCTestCase {
    func testTaggedItemRoundTripsThroughCodable() throws {
        let item = TaggedItem(name: "状态管理", score: 0.8)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TaggedItem.self, from: data)
        XCTAssertEqual(decoded, item)
    }
}
```

This also proves `@testable import AudioNote` resolves against the app target, which every later task depends on.

- [ ] **Step 2: Regenerate the project so the new test file is picked up**

```sh
cd /Users/karsa/proj/audionote/ios && xcodegen --spec project.yml
```

Expected: `project.pbxproj` gains a reference to `SmokeTests.swift`. If it doesn't, the `sources: - path: AudioNoteTests` glob isn't matching and the test won't compile — stop and fix `project.yml` first.

- [ ] **Step 3: Run the test and verify it passes**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722'
```

Expected: `Test Suite 'SmokeTests' passed` — 1 test, 0 failures.

If the destination fails because that simulator no longer exists, run `xcrun simctl list devices available` and substitute a booted iOS 18.5+ simulator (18.5+ matters only for `simslim`, not for tests).

- [ ] **Step 4: Commit**

```sh
git add ios/AudioNoteTests/SmokeTests.swift ios/AudioNote.xcodeproj
git commit -m "test: add first unit test to the project"
```

---

### Task 1: `NoteRelation` model

**Files:**
- Create: `ios/AudioNote/Models/NoteRelation.swift`
- Test: `ios/AudioNoteTests/NoteRelationTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `struct NoteRelation: Codable, Hashable` with `let a: UUID`, `let b: UUID`, `let score: Double`
  - `var key: String` — `"<min uuid>|<max uuid>"`, identical regardless of argument order
  - `func involves(_ id: UUID) -> Bool`
  - `var otherID: (from: UUID) -> UUID?`
  - `struct RelatedNote: Identifiable, Hashable` with `let id: UUID` (the *other* note), `let score: Double`

- [ ] **Step 1: Write the failing tests**

Create `ios/AudioNoteTests/NoteRelationTests.swift`:

```swift
import XCTest
@testable import AudioNote

final class NoteRelationTests: XCTestCase {

    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testKeyIsIdenticalRegardlessOfArgumentOrder() {
        XCTAssertEqual(NoteRelation(a: a, b: b, score: 0.9).key,
                       NoteRelation(a: b, b: a, score: 0.4).key)
    }

    func testInvolvesMatchesEitherEndpoint() {
        let edge = NoteRelation(a: a, b: b, score: 0.9)
        XCTAssertTrue(edge.involves(a))
        XCTAssertTrue(edge.involves(b))
        XCTAssertFalse(edge.involves(c))
    }

    func testOtherIDReturnsTheCounterpart() {
        let edge = NoteRelation(a: a, b: b, score: 0.9)
        XCTAssertEqual(edge.otherID(from: a), b)
        XCTAssertEqual(edge.otherID(from: b), a)
        XCTAssertNil(edge.otherID(from: c))
    }

    func testRoundTripsThroughCodable() throws {
        let edge = NoteRelation(a: a, b: b, score: 0.73)
        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(NoteRelation.self, from: data)
        XCTAssertEqual(decoded.a, edge.a)
        XCTAssertEqual(decoded.b, edge.b)
        XCTAssertEqual(decoded.score, edge.score, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run and verify it fails**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/NoteRelationTests
```

Expected: compile failure — `cannot find 'NoteRelation' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/AudioNote/Models/NoteRelation.swift`:

```swift
import Foundation

/// One undirected "these two notes are related" edge.
///
/// `a` and `b` carry no directional meaning. The writer normalizes them so
/// that `a.uuidString < b.uuidString`, which makes `(A,B)` and `(B,A)` the
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
```

- [ ] **Step 4: Regenerate the project and run the tests**

```sh
cd /Users/karsa/proj/audionote/ios && xcodegen --spec project.yml
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/NoteRelationTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```sh
git add ios/AudioNote/Models/NoteRelation.swift ios/AudioNoteTests/NoteRelationTests.swift ios/AudioNote.xcodeproj
git commit -m "feat(related): add NoteRelation undirected-edge model"
```

---

### Task 2: `RelatedNotesStorage`

**Files:**
- Create: `ios/AudioNote/Services/RelatedNotesStorage.swift`
- Modify: `ios/AudioNote/Services/StorageCoordinator.swift` (add `relatedNotesURL`)
- Test: `ios/AudioNoteTests/RelatedNotesStorageTests.swift`

**Interfaces:**
- Consumes: `NoteRelation`, `RelatedNote` (Task 1); `StorageCoordinator.relatedNotesURL` (added in this task)
- Produces:
  - `final class RelatedNotesStorage` — private-init singleton, `static let shared`
  - `static let minimumScore: Double = 0.3`
  - `func loadAll() async throws -> [NoteRelation]` — missing file returns `[]`
  - `func related(to id: UUID) async -> [RelatedNote]` — counterpart ids, `score >= minimumScore`, sorted descending
  - `func upsert(_ relations: [NoteRelation]) async throws` — de-dupes by `key`, replaces score on an existing edge
  - `func removeAll(involving id: UUID) async throws` — drops every edge touching `id`
  - `StorageCoordinator.relatedNotesURL: URL` (`nonisolated`)

> **Testability note:** the singleton reads its path from `StorageCoordinator`, which is only `isReady` after a real folder pick — impossible in a unit test. So the file-facing logic lives in an `internal` `store(at:)` initializer that tests drive with a temp directory. The singleton is a thin wrapper over it.

- [ ] **Step 1: Add `relatedNotesURL` to `StorageCoordinator`**

In `ios/AudioNote/Services/StorageCoordinator.swift`, directly after the existing `jsonURL` (line ~228-230):

```swift
    nonisolated var relatedNotesURL: URL {
        rootURL.appendingPathComponent("relatedNotes.json")
    }
```

- [ ] **Step 2: Write the failing tests**

Create `ios/AudioNoteTests/RelatedNotesStorageTests.swift`:

```swift
import XCTest
@testable import AudioNote

final class RelatedNotesStorageTests: XCTestCase {

    private var tmpDir: URL!
    private var store: RelatedNotesStorage!
    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = RelatedNotesStorage(fileURL: tmpDir.appendingPathComponent("relatedNotes.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testLoadAllReturnsEmptyWhenFileMissing() async throws {
        let all = try await store.loadAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testUpsertThenLoadRoundTrips() async throws {
        try await store.upsert([NoteRelation(a: a, b: b, score: 0.9)])
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.score ?? 0, 0.9, accuracy: 0.0001)
    }

    func testUpsertReversedOrderDoesNotDuplicate() async throws {
        try await store.upsert([NoteRelation(a: a, b: b, score: 0.9)])
        try await store.upsert([NoteRelation(a: b, b: a, score: 0.4)])
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1, "same undirected pair must not duplicate")
        XCTAssertEqual(all.first?.score ?? 0, 0.4, accuracy: 0.0001, "later write replaces the score")
    }

    func testRelatedReturnsBothSidesSortedDescending() async throws {
        try await store.upsert([
            NoteRelation(a: a, b: b, score: 0.3),
            NoteRelation(a: a, b: c, score: 0.8),
        ])
        let related = await store.related(to: a)
        XCTAssertEqual(related.map(\.id), [c, b], "descending by score")

        let fromB = await store.related(to: b)
        XCTAssertEqual(fromB.map(\.id), [a], "counterpart, not the queried id")
    }

    func testRelatedOmitsEdgesBelowMinimumScore() async throws {
        try await store.upsert([
            NoteRelation(a: a, b: b, score: 0.29),
            NoteRelation(a: a, b: c, score: RelatedNotesStorage.minimumScore),
        ])
        let related = await store.related(to: a)
        XCTAssertEqual(related.map(\.id), [c], "threshold is inclusive; 0.29 is hidden")
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 2, "hidden edges are still stored")
    }

    func testRemoveAllInvolvingDropsOnlyMatchingEdges() async throws {
        try await store.upsert([
            NoteRelation(a: a, b: b, score: 0.9),
            NoteRelation(a: b, b: c, score: 0.5),
        ])
        try await store.removeAll(involving: a)
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.key, NoteRelation(a: b, b: c, score: 0).key)
    }

    func testLoadAllOnCorruptFileThrowsAndLeavesFileIntact() async throws {
        let url = tmpDir.appendingPathComponent("relatedNotes.json")
        try Data("{ this is not json".utf8).write(to: url)
        do {
            _ = try await store.loadAll()
            XCTFail("expected a decode failure")
        } catch {
            // Expected. The caller (RelatedNotesService / detail view) swallows
            // this; the point is that it throws rather than crashing.
        }
    }
}
```

- [ ] **Step 3: Run and verify it fails**

```sh
cd /Users/karsa/proj/audionote/ios && xcodegen --spec project.yml
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesStorageTests
```

Expected: compile failure — `cannot find 'RelatedNotesStorage' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/AudioNote/Services/RelatedNotesStorage.swift`:

```swift
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
        var merged = Dictionary(uniqueKeysWithValues: (try? await loadAll() ?? [])
            .map { ($0.key, $0) })
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
```

- [ ] **Step 5: Run the tests and verify they pass**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesStorageTests
```

Expected: 7 tests pass. `testLoadAllOnCorruptFileThrowsAndLeavesFileIntact` confirms a malformed file throws rather than crashing — callers swallow it.

- [ ] **Step 6: Commit**

```sh
git add ios/AudioNote/Services/RelatedNotesStorage.swift ios/AudioNote/Services/StorageCoordinator.swift ios/AudioNoteTests/RelatedNotesStorageTests.swift ios/AudioNote.xcodeproj
git commit -m "feat(related): add RelatedNotesStorage backed by relatedNotes.json"
```

---

### Task 3: `RelatedNotesService.prescreen` (pure function)

**Files:**
- Create: `ios/AudioNote/Services/RelatedNotesService.swift` (prescreen + sanitize only; networking comes in Task 5)
- Test: `ios/AudioNoteTests/RelatedNotesPrescreenTests.swift`

**Interfaces:**
- Consumes: `TranscriptionRecord`, `TaggedItem`
- Produces:
  - `struct RelatedNotesService` with
    - `static let maxCandidates = 20`
    - `static let minimumCandidates = 3`
    - `static func prescreen(current: TranscriptionRecord, among: [TranscriptionRecord]) -> [TranscriptionRecord]`
    - `static func sanitize(_ matches: [RelatedNoteMatch], candidateIDs: Set<UUID>, currentID: UUID) -> [RelatedNoteMatch]` (sanitize takes `RelatedNoteMatch`, defined in Task 4 — declare that struct in Task 4 and add this test there; see note)

> **Ordering note:** `prescreen` is a pure static function with no networking, so it is fully testable in this task. `sanitize` depends on `RelatedNoteMatch`, which is introduced in Task 4 — **the sanitize tests live in Task 4**, not here. This task ships prescreen only.

- [ ] **Step 1: Write the failing tests**

Create `ios/AudioNoteTests/RelatedNotesPrescreenTests.swift`:

```swift
import XCTest
@testable import AudioNote

final class RelatedNotesPrescreenTests: XCTestCase {

    private let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private func record(
        id: UUID,
        tags: [TaggedItem] = [],
        archived: Bool = false,
        status: LLMStatus = .completed,
        createdAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> TranscriptionRecord {
        var r = TranscriptionRecord(id: id, content: "x", createdAt: createdAt)
        r.tags = tags
        r.archived = archived
        r.llmProcessingStatus = status
        return r
    }

    private let tA = TaggedItem(name: "状态管理", score: 0.9)
    private let tB = TaggedItem(name: "单例", score: 0.7)
    private let tC = TaggedItem(name: "架构", score: 0.5)

    func testSharesMoreTagsRanksHigher() {
        let current = record(id: currentID, tags: [tA, tB, tC])
        let two = record(id: UUID(), tags: [tA, tB])
        let one = record(id: UUID(), tags: [tA])
        let none = record(id: UUID(), tags: [TaggedItem(name: "别的", score: 0.9)])

        let ranked = RelatedNotesService.prescreen(current: current, among: [none, one, two])
        XCTAssertEqual(ranked.map(\.id), [two.id, one.id, none.id])
    }

    func testExcludesSelf() {
        let current = record(id: currentID, tags: [tA])
        let other = record(id: UUID(), tags: [tA])
        let ranked = RelatedNotesService.prescreen(current: current, among: [current, other])
        XCTAssertEqual(ranked.map(\.id), [other.id])
    }

    func testExcludesArchivedAndUnprocessed() {
        let current = record(id: currentID, tags: [tA])
        let archived = record(id: UUID(), tags: [tA], archived: true)
        let pending = record(id: UUID(), tags: [tA], status: .pending)
        let ok = record(id: UUID(), tags: [tA])

        let ranked = RelatedNotesService.prescreen(current: current, among: [archived, pending, ok])
        XCTAssertEqual(ranked.map(\.id), [ok.id])
    }

    func testTiesBreakOnCreatedAtDescendingAndAreDeterministic() {
        let current = record(id: currentID, tags: [tA])
        let older = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                           tags: [tA], createdAt: Date(timeIntervalSince1970: 100))
        let newer = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                           tags: [tA], createdAt: Date(timeIntervalSince1970: 900))

        let first = RelatedNotesService.prescreen(current: current, among: [older, newer])
        let second = RelatedNotesService.prescreen(current: current, among: [newer, older])
        XCTAssertEqual(first.map(\.id), [newer.id, older.id])
        XCTAssertEqual(first.map(\.id), second.map(\.id), "input order must not change the result")
    }

    func testCapsAtMaxCandidates() {
        let current = record(id: currentID, tags: [tA])
        let many = (0..<50).map { _ in record(id: UUID(), tags: [tA]) }
        let ranked = RelatedNotesService.prescreen(current: current, among: many)
        XCTAssertEqual(ranked.count, RelatedNotesService.maxCandidates)
    }
}
```

- [ ] **Step 2: Run and verify it fails**

```sh
cd /Users/karsa/proj/audionote/ios && xcodegen --spec project.yml
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesPrescreenTests
```

Expected: compile failure — `cannot find 'RelatedNotesService' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/AudioNote/Services/RelatedNotesService.swift`:

```swift
import Foundation

/// Owns prescreen → LLM → sanitize → persist for related notes.
/// Knows nothing about SwiftUI. `link(for:)` never throws.
struct RelatedNotesService {

    static let maxCandidates = 20
    static let minimumCandidates = 3

    // MARK: - Prescreen (pure, local, free)

    /// Rank existing notes by how likely they are to be related, locally.
    ///
    /// score = 2.0 × (shared tag count)
    ///       + 0.5 × log2(1 + mean score of the shared tags)
    ///       + 0.3 × recency decay
    ///
    /// The tag-count term dominates; the recency term only breaks ties among
    /// equal-overlap notes. Ordering is fully deterministic (ties fall back
    /// to `createdAt` descending) so the candidate set handed to the LLM
    /// never reshuffles between runs over identical input.
    static func prescreen(current: TranscriptionRecord, among: [TranscriptionRecord]) -> [TranscriptionRecord] {
        let currentTags = Dictionary(current.tags ?? [], uniquingKeysWith: { first, _ in first })
        guard !currentTags.isEmpty else { return [] }

        let now = Date()
        let scored: [(record: TranscriptionRecord, score: Double)] = among.compactMap { candidate in
            guard candidate.id != current.id,
                  candidate.archived != true,
                  candidate.llmProcessingStatus == .completed,
                  let candidateTags = candidate.tags, !candidateTags.isEmpty
            else { return nil }

            let sharedNames = Set(candidateTags.map(\.name))
                .intersection(Set(currentTags.keys))
            guard !sharedNames.isEmpty else { return nil }

            let sharedScores = sharedNames.map { name -> Double in
                min(currentTags[name]?.score ?? 0, candidate.score(forTagName: name) ?? 0)
            }
            let tagCount = Double(sharedNames.count)
            let meanTagScore = sharedScores.reduce(0, +) / sharedScores.count
            let ageDays = max(0, now.timeIntervalSince(candidate.createdAt) / 86_400)
            let recency = 1.0 / (1.0 + ageDays / 30.0)

            let score = 2.0 * tagCount + 0.5 * log2(1 + meanTagScore) + 0.3 * recency
            return (candidate, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.record.createdAt != rhs.record.createdAt { return lhs.record.createdAt > rhs.record.createdAt }
                return lhs.record.id.uuidString < rhs.record.id.uuidString
            }
            .prefix(Self.maxCandidates)
            .map(\.record)
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesPrescreenTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```sh
git add ios/AudioNote/Services/RelatedNotesService.swift ios/AudioNoteTests/RelatedNotesPrescreenTests.swift ios/AudioNote.xcodeproj
git commit -m "feat(related): add deterministic local prescreen ranking"
```

---

### Task 4: `LLMService.findRelated` + `sanitize`

**Files:**
- Modify: `ios/AudioNote/Services/LLMService.swift` (add wire types, prompt, entry point, parser)
- Modify: `ios/AudioNote/Services/RelatedNotesService.swift` (add `sanitize`)
- Test: `ios/AudioNoteTests/RelatedNotesSanitizeTests.swift`
- Test: `ios/AudioNoteTests/FindRelatedParsingTests.swift`

**Interfaces:**
- Consumes: `LLMService.retryingRequest` (existing, private), `LLMService.validateProfile` (existing, private), `NetworkMonitor.shared.checkConnectivity()` (existing)
- Produces:
  - `struct RelatedNoteCandidate: Encodable` — `id: UUID`, `title: String`, `summary: String`
  - `struct RelatedNoteMatch: Decodable` — `id: UUID`, `score: Double`
  - `struct RelatedPayload: Decodable` — `related: [RelatedNoteMatch]`
  - `LLMService.findRelated(currentTitle:currentSummary:candidates:profile:apiKey:) async throws -> [RelatedNoteMatch]`
  - `LLMService.parseRelated(content:) throws -> [RelatedNoteMatch]` (internal static, for tests)
  - `RelatedNotesService.sanitize(_:candidateIDs:currentID:) -> [RelatedNoteMatch]`

- [ ] **Step 1: Write the failing sanitize tests**

Create `ios/AudioNoteTests/RelatedNotesSanitizeTests.swift`:

```swift
import XCTest
@testable import AudioNote

final class RelatedNotesSanitizeTests: XCTestCase {

    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let hallucinated = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

    func testDropsIdsOutsideTheCandidateSet() {
        let input = [
            RelatedNoteMatch(id: a, score: 0.9),
            RelatedNoteMatch(id: hallucinated, score: 0.95),
        ]
        let out = RelatedNotesService.sanitize(input, candidateIDs: [a, b], currentID: UUID())
        XCTAssertEqual(out.map(\.id), [a])
    }

    func testDropsTheCurrentNote() {
        let input = [RelatedNoteMatch(id: a, score: 0.9), RelatedNoteMatch(id: b, score: 0.4)]
        let out = RelatedNotesService.sanitize(input, candidateIDs: [a, b], currentID: a)
        XCTAssertEqual(out.map(\.id), [b])
    }

    func testDeduplicatesKeepingHighestScore() {
        let input = [
            RelatedNoteMatch(id: a, score: 0.3),
            RelatedNoteMatch(id: a, score: 0.9),
        ]
        let out = RelatedNotesService.sanitize(input, candidateIDs: [a], currentID: UUID())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.score ?? 0, 0.9, accuracy: 0.0001)
    }

    func testCapsAtFiveStrongest() {
        let ids = (0..<9).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        let input = ids.enumerated().map { RelatedNoteMatch(id: $0.element, score: Double($0.offset) / 10) }
        let out = RelatedNotesService.sanitize(input, candidateIDs: Set(ids), currentID: UUID())
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out.map(\.score), [0.8, 0.7, 0.6, 0.5, 0.4])
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertTrue(RelatedNotesService.sanitize([], candidateIDs: [a], currentID: UUID()).isEmpty)
    }
}
```

- [ ] **Step 2: Write the failing parsing tests**

Create `ios/AudioNoteTests/FindRelatedParsingTests.swift`:

```swift
import XCTest
@testable import AudioNote

final class FindRelatedParsingTests: XCTestCase {

    func testParsesDirectJSON() throws {
        let json = #"{"related":[{"id":"11111111-1111-1111-1111-111111111111","score":0.9}]}"#
        let out = try LLMService.parseRelated(content: json)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.score ?? 0, 0.9, accuracy: 0.0001)
    }

    func testParsesProseWrappedJSON() throws {
        let prose = """
        好的，我分析了这些候选笔记。结果如下：
        {"related":[{"id":"11111111-1111-1111-1111-111111111111","score":0.75}]}
        希望对你有帮助。
        """
        let out = try LLMService.parseRelated(content: prose)
        XCTAssertEqual(out.count, 1)
    }

    func testParsesEmptyRelatedArray() throws {
        let out = try LLMService.parseRelated(content: #"{"related":[]}"#)
        XCTAssertTrue(out.isEmpty, "no relation is a valid answer, not an error")
    }

    func testThrowsOnUnparseableContent() {
        XCTAssertThrowsError(try LLMService.parseRelated(content: "I cannot help with that."))
    }
}
```

- [ ] **Step 3: Run and verify both suites fail**

```sh
cd /Users/karsa/proj/audionote/ios && xcodegen --spec project.yml
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesSanitizeTests \
  -only-testing:AudioNoteTests/FindRelatedParsingTests
```

Expected: compile failure — `cannot find 'RelatedNoteMatch' in scope` / `cannot find 'sanitize'`.

- [ ] **Step 4: Add the wire types, prompt, entry point, and parser to `LLMService.swift`**

Add these near the existing wire types (after `APIResponse`, ~line 100):

```swift
    struct RelatedNoteCandidate: Encodable {
        let id: UUID
        let title: String
        let summary: String
    }

    struct RelatedNoteMatch: Decodable {
        let id: UUID
        let score: Double
    }

    private struct RelatedPayload: Decodable {
        let related: [RelatedNoteMatch]?
    }
```

Add the prompt as a `private static let` beside `optimizeAndProcessPrompt` (~line 131):

```swift
    private static let findRelatedPrompt = """
    你是一个笔记关联助手。下面是一条笔记，以及候选笔记的列表。

    【当前笔记】
    标题：{title}
    摘要：{summary}

    【候选笔记】
    {candidates}

    请选出与【当前笔记】在主题或内容上真正相关的候选，最多 5 条，不足则少给。
    只返回你确实认为相关的；如果没有任何一条相关，返回空数组。
    不要返回格式错误的 id，不要编造候选列表中不存在的 id。
    id 字段必须是上面给定的完整 uuid 字符串。
    score 是这一对笔记的相关程度，0.0-1.0，与候选列表的规模无关：
    即使只有一条候选也要如实给分。

    严格返回 JSON，不要任何解释或 markdown 标记：
    {"related": [{"id": "<uuid>", "score": 0.85}]}
    """
```

Add the entry point after `optimizeAndProcess` (~line 160):

```swift
    /// Second, independent LLM call: which of the given candidates are
    /// actually related to the current note. Kept separate from
    /// `optimizeAndProcess` because that call's user message is the raw
    /// transcript and its prompt asks the model to rewrite it — injecting
    /// 20 other notes' summaries into the same message invites the model to
    /// import them into the "optimized" output.
    func findRelated(
        currentTitle: String,
        currentSummary: String,
        candidates: [RelatedNoteCandidate],
        profile: LLMProviderProfile,
        apiKey: String?
    ) async throws -> [RelatedNoteMatch] {
        try validateProfile(profile, apiKey: apiKey)

        let candidateBlock = candidates
            .map { "\($0.id.uuidString). 标题：\($0.title) 摘要：\($0.summary)" }
            .joined(separator: "\n")

        let systemPrompt = Self.findRelatedPrompt
            .replacingOccurrences(of: "{title}", with: currentTitle)
            .replacingOccurrences(of: "{summary}", with: currentSummary)
            .replacingOccurrences(of: "{candidates}", with: candidateBlock)

        return try await retryingRequest(
            profile: profile,
            apiKey: apiKey,
            buildRequest: {
                APIRequest(
                    model: profile.model,
                    messages: [
                        APIRequest.Message(role: "system", content: systemPrompt),
                        APIRequest.Message(role: "user", content: "请找出相关笔记。"),
                    ]
                )
            },
            sendAndParse: { urlRequest, profile in
                let content = try await self.sendAndExtractContent(urlRequest: urlRequest, profile: profile)
                return try Self.parseRelated(content: content)
            }
        )
    }
```

Add the parser next to `parseOptimizeAndProcess` (~line 354). It reuses the existing `extractFirstJSONObject` helper:

```swift
    /// Parse the `findRelated` response. Direct JSON first, then the same
    /// balanced-brace extraction used by `parseOptimizeAndProcess` (models in
    /// the M2.7 lineage wrap JSON in prose). An empty `related` array is a
    /// valid answer, not an error.
    static func parseRelated(content: String) throws -> [RelatedNoteMatch] {
        let decode: (Data) -> [RelatedNoteMatch]? = { data in
            guard let payload = try? JSONDecoder().decode(RelatedPayload.self, from: data) else { return nil }
            return payload.related ?? []
        }

        if let directData = content.data(using: .utf8), let parsed = decode(directData) {
            return parsed
        }

        if let extracted = extractFirstJSONObject(from: content),
           let extractedData = extracted.data(using: .utf8),
           let parsed = decode(extractedData) {
            return parsed
        }

        Logger.error("LLM findRelated: could not parse content: \(content)")
        throw LLMError.decodingError
    }
```

- [ ] **Step 5: Add `sanitize` to `RelatedNotesService.swift`**

Append inside the struct (after `prescreen`):

```swift
    // MARK: - Sanitize (pure)

    /// Drop anything the model shouldn't have returned: ids that weren't
    /// offered as candidates (hallucinations), the current note itself, and
    /// duplicates. Keeps the strongest score per surviving id and caps the
    /// result at 5, ordered strongest first.
    static func sanitize(
        _ matches: [RelatedNoteMatch],
        candidateIDs: Set<UUID>,
        currentID: UUID
    ) -> [RelatedNoteMatch] {
        var best: [UUID: Double] = [:]
        for match in matches where candidateIDs.contains(match.id) && match.id != currentID {
            best[match.id] = max(best[match.id] ?? 0, match.score)
        }
        return best
            .map { RelatedNoteMatch(id: $0.key, score: $0.value) }
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map { $0 }
    }
```

- [ ] **Step 6: Run both suites and verify they pass**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesSanitizeTests \
  -only-testing:AudioNoteTests/FindRelatedParsingTests
```

Expected: 9 tests pass (5 sanitize + 4 parsing).

- [ ] **Step 7: Commit**

```sh
git add ios/AudioNote/Services/LLMService.swift ios/AudioNote/Services/RelatedNotesService.swift ios/AudioNoteTests/RelatedNotesSanitizeTests.swift ios/AudioNoteTests/FindRelatedParsingTests.swift
git commit -m "feat(related): add findRelated LLM call and output sanitizer"
```

---

### Task 5: Wire `RelatedNotesService.link(for:)` into the write path

**Files:**
- Modify: `ios/AudioNote/Services/RelatedNotesService.swift` (add `link(for:)`, storage dep, actor isolation)
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` (call it after the record save in `processWithLLM`)
- Test: `ios/AudioNoteTests/RelatedNotesLinkTests.swift`

**Interfaces:**
- Consumes: `RelatedNotesService.prescreen` / `.sanitize` (Tasks 3–4), `RelatedNotesStorage` (Task 2), `LLMService.findRelated` (Task 4), `TranscriptionStorage` (existing), `ProviderProfileStore` (existing)
- Produces:
  - `RelatedNotesService` gains an initializer: `init(storage: RelatedNotesStorage = .shared, records: TranscriptionStorage = .shared, llm: LLMService = .shared)`
  - `func link(for recordId: UUID) async` — never throws
  - `TranscriptionViewModel` calls `await relatedNotesService.link(for: record.id)` after its existing `storage.save(record)`

> **Concurrency:** `link(for:)` is serialized through an `actor` guard so two overlapping triggers (a fast second recording, or `networkDidRecover` firing alongside) can't interleave a read-modify-write on `relatedNotes.json`.

- [ ] **Step 1: Write the failing tests**

Create `ios/AudioNoteTests/RelatedNotesLinkTests.swift`:

```swift
import XCTest
@testable import AudioNote

final class RelatedNotesLinkTests: XCTestCase {

    private var tmpDir: URL!
    private var relations: RelatedNotesStorage!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        relations = RelatedNotesStorage(fileURL: tmpDir.appendingPathComponent("relatedNotes.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func tagged(_ id: UUID, _ names: [String], archived: Bool = false) -> TranscriptionRecord {
        var r = TranscriptionRecord(id: id, content: "content for \(id)", createdAt: Date())
        r.title = "标题 \(id)"
        r.summary = "摘要 \(id)"
        r.tags = names.enumerated().map { TaggedItem(name: $0.element, score: 0.9 - Double($0.offset) * 0.1) }
        r.llmProcessingStatus = .completed
        r.archived = archived
        return r
    }

    func testLinkDoesNothingWhenTooFewCandidates() async throws {
        let current = tagged(UUID(), ["a", "b"])
        try await relations.upsert([]) // no edges
        let service = RelatedNotesService(storage: relations, records: InMemoryRecords([current]), llm: StubLLM())

        await service.link(for: current.id)

        let edges = try await relations.loadAll()
        XCTAssertTrue(edges.isEmpty, "fewer than minimumCandidates must not call the LLM")
    }

    func testLinkWritesOneEdgePerMatch() async throws {
        let current = tagged(UUID(), ["a", "b", "c"])
        let x = tagged(UUID(), ["a", "b"])
        let y = tagged(UUID(), ["a", "c"])
        let z = tagged(UUID(), ["a", "b"])

        let llm = StubLLM(returns: [
            RelatedNoteMatch(id: x.id, score: 0.9),
            RelatedNoteMatch(id: y.id, score: 0.5),
            RelatedNoteMatch(id: z.id, score: 0.7),
        ])
        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords([current, x, y, z]),
            llm: llm
        )

        await service.link(for: current.id)

        let edges = try await relations.loadAll()
        XCTAssertEqual(edges.count, 3)
        XCTAssertEqual(llm.callCount, 1)
        XCTAssertTrue(edges.allSatisfy { $0.involves(current.id) })
    }

    func testLinkIsIdempotent() async throws {
        let current = tagged(UUID(), ["a", "b"])
        let x = tagged(UUID(), ["a", "b"])

        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords([current, x]),
            llm: StubLLM(returns: [RelatedNoteMatch(id: x.id, score: 0.8)])
        )

        await service.link(for: current.id)
        await service.link(for: current.id)

        let edges = try await relations.loadAll()
        XCTAssertEqual(edges.count, 1, "re-linking must not duplicate the edge")
    }

    func testLLMFailureLeavesNoEdgesAndDoesNotThrow() async throws {
        let current = tagged(UUID(), ["a", "b", "c"])
        let x = tagged(UUID(), ["a", "b"])
        let y = tagged(UUID(), ["a", "c"])
        let z = tagged(UUID(), ["a", "b"])

        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords([current, x, y, z]),
            llm: StubLLM(error: LLMError.decodingError)
        )

        await service.link(for: current.id) // must not throw

        let edges = try await relations.loadAll()
        XCTAssertTrue(edges.isEmpty)
    }

    func testArchivedCandidateIsNeverSent() async throws {
        let current = tagged(UUID(), ["a", "b", "c"])
        let live = tagged(UUID(), ["a", "b"])
        let archived = tagged(UUID(), ["a", "c"], archived: true)
        let other = tagged(UUID(), ["a", "b"])

        let llm = StubLLM(returns: [RelatedNoteMatch(id: live.id, score: 0.8)])
        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords([current, live, archived, other]),
            llm: llm
        )

        await service.link(for: current.id)

        let edges = try await relations.loadAll()
        XCTAssertFalse(edges.contains { $0.involves(archived.id) })
    }
}
```

Add the test doubles at the bottom of the same file:

```swift
// MARK: - Test doubles

/// In-memory stand-in for `TranscriptionStorage`'s read path. The real one
/// needs a bootstrapped folder; `link(for:)` only ever calls `loadAll()`.
struct InMemoryRecords: RecordsSource {
    let all: [TranscriptionRecord]
    func loadAll() async throws -> [TranscriptionRecord] { all }
}

struct StubLLM: RelatedNotesLLM {
    var callCount = 0
    var lastCandidateIDs: [UUID] = []
    private let returns: [RelatedNoteMatch]
    private let error: Error?

    init(returns: [RelatedNoteMatch] = [], error: Error? = nil) {
        self.returns = returns
        self.error = error
    }

    func findRelated(
        currentTitle: String,
        currentSummary: String,
        candidates: [LLMService.RelatedNoteCandidate],
        profile: LLMProviderProfile,
        apiKey: String?
    ) async throws -> [LLMService.RelatedNoteMatch] {
        callCount += 1
        lastCandidateIDs = candidates.map(\.id)
        if let error { throw error }
        return returns
    }
}
```

- [ ] **Step 2: Run and verify it fails**

```sh
cd /Users/karsa/proj/audionote/ios && xcodegen --spec project.yml
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesLinkTests
```

Expected: compile failure — `cannot find 'RecordsSource' in scope` / `cannot find 'RelatedNotesLLM' in scope`.

- [ ] **Step 3: Add the protocols and `link(for:)` to `RelatedNotesService.swift`**

Add at file scope, above `struct RelatedNotesService`:

```swift
/// Read-only view of the note store. Lets `link(for:)` be tested without a
/// bootstrapped folder; `TranscriptionStorage` satisfies it as-is.
protocol RecordsSource {
    func loadAll() async throws -> [TranscriptionRecord]
}

/// The slice of `LLMService` that `link(for:)` needs.
protocol RelatedNotesLLM {
    func findRelated(
        currentTitle: String,
        currentSummary: String,
        candidates: [LLMService.RelatedNoteCandidate],
        profile: LLMProviderProfile,
        apiKey: String?
    ) async throws -> [LLMService.RelatedNoteMatch]
}
```

Make `LLMService` conform — add at file scope in `LLMService.swift`:

```swift
extension LLMService: RelatedNotesLLM {}
```

Change the struct declaration and add the initializer + `link(for:)`:

```swift
struct RelatedNotesService {

    static let maxCandidates = 20
    static let minimumCandidates = 3

    private let storage: RelatedNotesStorage
    private let records: RecordsSource
    private let llm: RelatedNotesLLM
    /// Serializes read-modify-write on relatedNotes.json.
    private let gate = Gate()

    init(
        storage: RelatedNotesStorage = .shared,
        records: RecordsSource = TranscriptionStorage.shared,
        llm: RelatedNotesLLM = LLMService()
    ) {
        self.storage = storage
        self.records = records
        self.llm = llm
    }
```

Add the actor and the orchestration method:

```swift
/// Minimal async mutex. `link(for:)` is the only serialized section.
actor Gate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
```

```swift
    /// Compute and persist relations for one note. Never throws: a failure
    /// here must not disturb the note's own save or surface to the user.
    func link(for recordId: UUID) async {
        await gate.acquire()
        defer { Task { await gate.release() } }

        do {
            guard let current = try await records.loadAll().first(where: { $0.id == recordId }),
                  current.llmProcessingStatus == .completed,
                  let title = current.title, !title.isEmpty,
                  let summary = current.summary, !summary.isEmpty
            else { return }

            let all = try await records.loadAll()
            let candidates = Self.prescreen(current: current, among: all)
            guard candidates.count >= Self.minimumCandidates else {
                Logger.info("Related notes skipped for \(recordId): only \(candidates.count) candidates")
                return
            }

            // Global constraint: every online call is connectivity-gated.
            // `NetworkMonitor` and `ProviderProfileStore` are both main-actor
            // isolated, so hop for both reads.
            let isOnline = await MainActor.run { NetworkMonitor.shared.checkConnectivity() }
            guard isOnline else {
                Logger.info("Related notes skipped for \(recordId): offline")
                return
            }
            let credentials: (profile: LLMProviderProfile, apiKey: String?)? = await MainActor.run {
                guard let profile = ProviderProfileStore.shared.active else { return nil }
                return (profile, ProviderProfileStore.shared.apiKey(for: profile.id))
            }
            guard let credentials else { return }

            let payload = candidates.map {
                LLMService.RelatedNoteCandidate(id: $0.id, title: $0.title ?? "", summary: $0.summary ?? "")
            }
            let raw = try await llm.findRelated(
                currentTitle: title,
                currentSummary: summary,
                candidates: payload,
                profile: credentials.profile,
                apiKey: credentials.apiKey
            )

            let sanitized = Self.sanitize(
                raw,
                candidateIDs: Set(candidates.map(\.id)),
                currentID: current.id
            )
            guard !sanitized.isEmpty else { return }

            try await storage.upsert(
                sanitized.map { NoteRelation(a: current.id, b: $0.id, score: $0.score) }
            )
            Logger.info("Related notes linked for \(recordId): \(sanitized.count) edges")
        } catch {
            Logger.warning("Related notes linking failed for \(recordId): \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 4: Add the conformance in `TranscriptionStorage.swift`**

At file scope, after the `TranscriptionStorage` class:

```swift
extension TranscriptionStorage: RecordsSource {}
```

- [ ] **Step 5: Call `link(for:)` from `TranscriptionViewModel`**

In `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`, in `processWithLLM` (line ~385), immediately after `try await storage.save(record)`:

```swift
            // Relations are best-effort: this never throws and never blocks
            // the note's own save. It runs after the record is persisted so a
            // slow or failing relation call cannot delay it.
            await relatedNotesService.link(for: record.id)
```

Add the property near the other injected services in the class (next to `llmService`):

```swift
    private let relatedNotesService = RelatedNotesService()
```

- [ ] **Step 6: Run the tests and verify they pass**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesLinkTests
```

Expected: 5 tests pass. `testLinkWritesOneEdgePerMatch` also asserts `llm.callCount == 1` — the LLM is called exactly once, never per candidate.

- [ ] **Step 7: Build both destinations**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild -scheme AudioNote -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
cd /Users/karsa/proj/audionote/ios && xcodebuild -scheme AudioNote \
  -destination 'platform=iOS,id=3C0B7BE4-2AEF-54E4-B937-9A0C96326420' build
```

Expected: `** BUILD SUCCEEDED **` for both. The device build catches anything iOS 15 wouldn't allow.

- [ ] **Step 8: Commit**

```sh
git add ios/AudioNote/Services/RelatedNotesService.swift ios/AudioNote/Services/LLMService.swift ios/AudioNote/Services/TranscriptionStorage.swift ios/AudioNote/ViewModels/TranscriptionViewModel.swift ios/AudioNoteTests/RelatedNotesLinkTests.swift
git commit -m "feat(related): link relations after each LLM-processed note"
```

---

### Task 6: Clean up edges on delete and archive

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` (delete path)
- Test: `ios/AudioNoteTests/RelatedNotesCleanupTests.swift`

**Interfaces:**
- Consumes: `RelatedNotesStorage.removeAll(involving:)` (Task 2)
- Produces: no new public API — deleting or archiving a note drops its edges

> **Where cleanup goes:** the spec (§5.8) says `TranscriptionStorage.delete` gains the call. But `TranscriptionStorage` is a pure file service with no access to the relations file's lifecycle, and unit-testing it means a bootstrapped folder. Putting the call in the view model's delete path is the same observable behavior with a testable seam. The `RelatedNotesStorageTests` from Task 2 already cover the mechanics.

- [ ] **Step 1: Write the failing test**

Create `ios/AudioNoteTests/RelatedNotesCleanupTests.swift`:

```swift
import XCTest
@testable import AudioNote

final class RelatedNotesCleanupTests: XCTestCase {

    private var tmpDir: URL!
    private var storage: RelatedNotesStorage!
    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        storage = RelatedNotesStorage(fileURL: tmpDir.appendingPathComponent("relatedNotes.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testDeletingANoteDropsEveryEdgeTouchingIt() async throws {
        try await storage.upsert([
            NoteRelation(a: a, b: b, score: 0.9),
            NoteRelation(a: a, b: c, score: 0.7),
            NoteRelation(a: b, b: c, score: 0.6),
        ])

        try await storage.removeAll(involving: a)

        let remaining = try await storage.loadAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertFalse(remaining.contains { $0.involves(a) })
    }

    func testCleanupIsIdempotent() async throws {
        try await storage.upsert([NoteRelation(a: a, b: b, score: 0.9)])
        try await storage.removeAll(involving: a)
        try await storage.removeAll(involving: a)
        XCTAssertTrue(try await storage.loadAll().isEmpty)
    }

    func testCleanupOnEmptyStoreDoesNotThrow() async throws {
        try await storage.removeAll(involving: a)
        XCTAssertTrue(try await storage.loadAll().isEmpty)
    }
}
```

- [ ] **Step 2: Run and verify it passes**

```sh
cd /Users/karsa/proj/audionote/ios && xcodegen --spec project.yml
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesCleanupTests
```

Expected: 3 tests pass — `removeAll` was implemented in Task 2. These tests pin the contract the wiring depends on.

If they fail, fix `removeAll` before continuing.

- [ ] **Step 3: Wire cleanup into the delete path**

In `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`, find the function that deletes a record (it calls `storage.delete(id:)`), and add the cleanup call immediately after:

```swift
            // Best-effort: if this fails the render path skips dangling edges.
            try? await RelatedNotesStorage.shared.removeAll(involving: id)
```

If no `deleteRecord`-style function exists yet, add one and call it from the detail view's delete affordance:

```swift
    func deleteRecord(id: UUID) async {
        do {
            try await storage.delete(id: id)
            try? await RelatedNotesStorage.shared.removeAll(involving: id)
            await loadHistory()
        } catch {
            Logger.error("Failed to delete record: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }
```

Do **not** add cleanup to the archive toggle — an archived note keeps its edges and is filtered at render time (spec §6), so unarchiving restores its relations for free.

- [ ] **Step 4: Build the simulator destination**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild -scheme AudioNote -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```sh
git add ios/AudioNoteTests/RelatedNotesCleanupTests.swift ios/AudioNote/ViewModels/TranscriptionViewModel.swift ios/AudioNote.xcodeproj
git commit -m "feat(related): drop edges when a note is deleted"
```

---

### Task 7: Detail-view section

**Files:**
- Modify: `ios/AudioNote/Views/TranscriptionDetailView.swift` (add `RelatedNotesSection`)
- Modify: `ios/AudioNote/Resources/en.lproj/Localizable.strings`
- Modify: `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings`
- Test: `ios/AudioNoteTests/RelatedNotesRowModelTests.swift`

**Interfaces:**
- Consumes: `RelatedNotesStorage.related(to:)` (Task 2), `TranscriptionRecord` (existing)
- Produces:
  - `struct RelatedNotesRow: Identifiable, Equatable` — `id: UUID`, `title: String`, `createdAt: Date`, `preview: String`, `sharedTags: [String]`, `record: TranscriptionRecord`
  - `enum RelatedNotesSectionBuilder` with `static func rows(for record: TranscriptionRecord, candidates: [TranscriptionRecord], related: [RelatedNote]) -> [RelatedNotesRow]`
  - New localization keys: `Related.Section.Title`, `Related.Section.Empty`

> **Why the view logic is a separate builder:** `TranscriptionDetailView` has no test coverage today and SwiftUI view bodies are impractical to unit-test. Extracting the mapping into a pure `RelatedNotesSectionBuilder` makes the skip-rules — missing record, archived record, no shared tags — testable without rendering anything.

- [ ] **Step 1: Write the failing tests**

Create `ios/AudioNoteTests/RelatedNotesRowModelTests.swift`:

```swift
import XCTest
@testable import AudioNote

final class RelatedNotesRowModelTests: XCTestCase {

    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let missing = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

    private func record(
        _ id: UUID,
        title: String = "标题",
        tags: [TaggedItem] = [],
        archived: Bool = false,
        content: String = "一段足够长的预览文本用来验证 preview 的截断行为是否正确"
    ) -> TranscriptionRecord {
        var r = TranscriptionRecord(id: id, content: content, createdAt: Date(timeIntervalSince1970: 1_000_000))
        r.title = title
        r.summary = "摘要"
        r.tags = tags
        r.llmProcessingStatus = .completed
        r.archived = archived
        return r
    }

    func testSkipsEdgesPointingAtMissingRecords() {
        let rows = RelatedNotesSectionBuilder.rows(
            for: record(a),
            candidates: [record(b)],
            related: [RelatedNote(id: b, score: 0.9), RelatedNote(id: missing, score: 0.8)]
        )
        XCTAssertEqual(rows.map(\.id), [b])
    }

    func testSkipsArchivedRecords() {
        let rows = RelatedNotesSectionBuilder.rows(
            for: record(a),
            candidates: [record(b, archived: true)],
            related: [RelatedNote(id: b, score: 0.9)]
        )
        XCTAssertTrue(rows.isEmpty, "an archived note must not appear as related")
    }

    func testKeepsOnlySharedTags() {
        let current = record(a, tags: [TaggedItem(name: "状态管理", score: 0.9), TaggedItem(name: "SwiftUI", score: 0.7)])
        let other = record(b, tags: [TaggedItem(name: "状态管理", score: 0.8), TaggedItem(name: "别的", score: 0.6)])
        let rows = RelatedNotesSectionBuilder.rows(for: current, candidates: [other], related: [RelatedNote(id: b, score: 0.9)])
        XCTAssertEqual(rows.first?.sharedTags, ["状态管理"])
    }

    func testEmptySharedTagsYieldsNoTagRow() {
        let current = record(a, tags: [TaggedItem(name: "甲", score: 0.9)])
        let other = record(b, tags: [TaggedItem(name: "乙", score: 0.9)])
        let rows = RelatedNotesSectionBuilder.rows(for: current, candidates: [other], related: [RelatedNote(id: b, score: 0.9)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].sharedTags.isEmpty)
    }

    func testSurvivesNoteWithNoTitleOrSummary() {
        var bare = TranscriptionRecord(id: b, content: "只有原始内容", createdAt: Date())
        bare.llmProcessingStatus = .completed
        let rows = RelatedNotesSectionBuilder.rows(
            for: record(a),
            candidates: [bare],
            related: [RelatedNote(id: b, score: 0.9)]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].title.isEmpty, "falls back rather than rendering an empty title")
    }

    func testPreservesScoreOrdering() {
        let rows = RelatedNotesSectionBuilder.rows(
            for: record(a),
            candidates: [record(b), record(c)],
            related: [RelatedNote(id: b, score: 0.4), RelatedNote(id: c, score: 0.9)]
        )
        XCTAssertEqual(rows.map(\.id), [c, b])
    }
}
```

- [ ] **Step 2: Run and verify it fails**

```sh
cd /Users/karsa/proj/audionote/ios && xcodegen --spec project.yml
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesRowModelTests
```

Expected: compile failure — `cannot find 'RelatedNotesSectionBuilder' in scope`.

- [ ] **Step 3: Add the row model and builder**

In `ios/AudioNote/Views/TranscriptionDetailView.swift`, above `struct TagFlowView`:

```swift
struct RelatedNotesRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let preview: String
    let sharedTags: [String]
    /// The record a `NavigationLink` pushes. Carried here so the row stays a
    /// plain value the builder can construct without a view model.
    let record: TranscriptionRecord
}

/// Pure mapping from stored edges to renderable rows, so the skip rules are
/// unit-testable without instantiating a SwiftUI view.
enum RelatedNotesSectionBuilder {

    static func rows(
        for record: TranscriptionRecord,
        candidates: [TranscriptionRecord],
        related: [RelatedNote]
    ) -> [RelatedNotesRow] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentTagNames = Set(record.tagNames)

        return related.compactMap { link -> RelatedNotesRow? in
            guard let other = byID[link.id], other.archived != true else { return nil }
            let shared = other.tagNames.filter { currentTagNames.contains($0) }
            return RelatedNotesRow(
                id: other.id,
                title: other.title?.isEmpty == false ? other.title! : other.preview,
                createdAt: other.createdAt,
                preview: other.preview,
                sharedTags: shared,
                record: other
            )
        }
    }
}
```

- [ ] **Step 4: Add the localization keys**

Append to `ios/AudioNote/Resources/en.lproj/Localizable.strings`:

```
"Related.Section.Title" = "Related Notes";
"Related.Section.Empty" = "(No related notes)";
```

Append to `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings`:

```
"Related.Section.Title" = "相关思考";
"Related.Section.Empty" = "（暂无相关笔记）";
```

- [ ] **Step 5: Add the section view**

In `ios/AudioNote/Views/TranscriptionDetailView.swift`, add the section struct after `RelatedNotesSectionBuilder`:

```swift
/// Rendered below the original/optimized text comparison. Hides itself
/// entirely when there is nothing to show — no empty state, no spinner.
/// Takes the view model separately so `RelatedNotesRow` stays a plain value.
struct RelatedNotesSection: View {
    let rows: [RelatedNotesRow]
    @ObservedObject var viewModel: TranscriptionViewModel

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Related.Section.Title".localized)
                    .font(.headline)

                ForEach(rows) { row in
                    NavigationLink {
                        TranscriptionDetailView(record: row.record, viewModel: viewModel)
                    } label: {
                        RelatedNotesRowView(row: row)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}
```

Then the row view:

```swift
struct RelatedNotesRowView: View {
    let row: RelatedNotesRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)

            HStack(spacing: 6) {
                Text(row.createdAt, style: .date)
                Text(row.createdAt, style: .time)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Text(row.preview)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)

            if !row.sharedTags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(row.sharedTags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}
```

- [ ] **Step 6: Render the section in the detail view**

In the detail view's main `ScrollView` content, immediately after the original/optimized text comparison block, add:

```swift
                let related = await RelatedNotesStorage.shared.related(to: currentRecord.id)
                RelatedNotesSection(
                    currentRecord: currentRecord,
                    rows: RelatedNotesSectionBuilder.rows(
                        for: currentRecord,
                        candidates: viewModel.historyRecords,
                        related: related,
                        viewModel: viewModel
                    )
                )
```

Because `related(to:)` is `async`, load it into `@State` in the view rather than calling it inline in `body`. Add:

```swift
    @State private var relatedNotes: [RelatedNote] = []
```

and a `.task`:

```swift
        .task(id: currentRecord.id) {
            relatedNotes = await RelatedNotesStorage.shared.related(to: currentRecord.id)
        }
```

then reference `relatedNotes` in the body:

```swift
                RelatedNotesSection(
                    currentRecord: currentRecord,
                    rows: RelatedNotesSectionBuilder.rows(
                        for: currentRecord,
                        candidates: viewModel.historyRecords,
                        related: relatedNotes,
                        viewModel: viewModel
                    )
                )
```

- [ ] **Step 7: Run the tests and verify they pass**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/RelatedNotesRowModelTests
```

Expected: 6 tests pass.

- [ ] **Step 8: Build both destinations**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild -scheme AudioNote -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
cd /Users/karsa/proj/audionote/ios && xcodebuild -scheme AudioNote \
  -destination 'platform=iOS,id=3C0B7BE4-2AEF-54E4-B937-9A0C96326420' build
```

Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 9: Commit**

```sh
git add ios/AudioNote/Views/TranscriptionDetailView.swift ios/AudioNote/Resources/en.lproj/Localizable.strings ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings ios/AudioNoteTests/RelatedNotesRowModelTests.swift
git commit -m "feat(related): render the related-notes section on the detail page"
```

---

### Task 8: Manual verification on device

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything from Tasks 0–7
- Produces: confirmation that the feature works end-to-end against a real Provider

- [ ] **Step 1: Build and install on the iPhone Air**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild -scheme AudioNote \
  -destination 'platform=iOS,id=3C0B7BE4-2AEF-54E4-B937-9A0C96326420' build
xcrun devicectl device install app \
  --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 \
  ~/Library/Developer/Xcode/DerivedData/AudioNote-*/Build/Products/Debug-iphoneos/AudioNote.app
xcrun devicectl device process launch \
  --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 info.karsa.app.ios.audionote
```

`devicectl` may print `Failed to load provisioning parameter list … No provider was found` on success — benign.

- [ ] **Step 2: Run the eight manual checks**

1. Record six notes on a shared topic. Each detail page shows a "相关思考" section.
2. Open note 1 — notes 2–6 appear. Open note 2 — note 1 and the overlapping notes appear. **Both pages show the same score ordering for the same pair.**
3. Record a seventh related note. Reopen note 1 — the section now has seven entries, still ordered by score.
4. Edit note 1's text, save. Its section is unchanged.
5. Turn on airplane mode, record a note. No section appears, and no error is shown.
6. Archive a note. It disappears from other notes' sections.
7. Delete a note. It disappears from other notes' sections with no gap.
8. Open `relatedNotes.json` in the Files app under `AudioNote/` — confirm the `[{"a":…,"b":…,"score":…}]` shape and that every `a` sorts before its `b`.

- [ ] **Step 3: Verify the first three notes' edge files are byte-stable**

Before and after step 3's new recording, read `relatedNotes.json` and diff it. Only **one new line** should appear. If existing lines were reordered or rescored, the append/upsert path is rewriting more than it should — stop and investigate `upsert`.

- [ ] **Step 4: Run the full test suite one more time**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722'
```

Expected: all suites green (1 smoke + 4 model + 7 storage + 5 prescreen + 5 sanitize + 4 parsing + 5 link + 3 cleanup + 6 row = 40 tests).

- [ ] **Step 5: Update the glossary and commit**

Add to `docs/GLOSSARY.md` under the Services section:

```markdown
| `NoteRelation` | One undirected "these two notes are related" edge, stored in `relatedNotes.json`. `a`/`b` are normalized so `a < b`, making the pair's identity order-independent (`key`). |
| `RelatedNotesStorage` | Reads/writes `relatedNotes.json` in the user's AudioNote folder. Filters and sorts by `score`, applies `minimumScore`. |
| `RelatedNotesService` | Orchestrates prescreen → LLM → sanitize → persist. `link(for:)` never throws. |
```

Then:

```sh
git add docs/GLOSSARY.md
git commit -m "docs(glossary): add related-notes terms"
```
