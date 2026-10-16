import XCTest
@testable import AudioNote

/// Tag hygiene at the two edges that create dirty data: what the LLM is told
/// (so it stops inventing near-synonyms and stray whitespace), and what the
/// app does with whatever comes back (so a dirty value is corrected once,
/// at the single place a tag can enter).
@MainActor
final class TagHygieneTests: XCTestCase {

    // MARK: - Fixtures

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        _ title: String,
        id: UUID = UUID(),
        tags: [TaggedItem] = [],
        archived: Bool = false,
        status: LLMStatus? = .completed
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            id: id,
            content: "\(title)的正文",
            createdAt: base,
            title: title,
            tags: tags.isEmpty ? nil : tags,
            llmProcessingStatus: status,
            archived: archived
        )
    }

    private func makeViewModel(_ records: [TranscriptionRecord]) -> TranscriptionViewModel {
        let vm = TranscriptionViewModel()
        vm.historyRecords = records
        return vm
    }

    // MARK: - Trimming, at the one place a tag can enter

    func testConstructingATagTrimsIt() {
        XCTAssertEqual(TaggedItem(name: " Work ", score: 1.0).name, "Work")
    }

    func testDecodingTrimsTagNames() throws {
        let json = """
        {"id":"\(UUID().uuidString)","content":"x","createdAt":0,
         "tags":[{"name":"  Work  ","score":0.5}]}
        """
        let decoded = try JSONDecoder().decode(
            TranscriptionRecord.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.tags?.map(\.name), ["Work"])
    }

    /// The legacy `[String]` shape took a different branch, so it needs its
    /// own proof — it is exactly the path that would otherwise keep emitting
    /// whitespace forever.
    func testLegacyStringTagsAreTrimmed() throws {
        let json = """
        {"id":"\(UUID().uuidString)","content":"x","createdAt":0,
         "tags":["  工作  "," 会议"]}
        """
        let decoded = try JSONDecoder().decode(
            TranscriptionRecord.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.tags?.map(\.name), ["工作", "会议"])
    }

    /// A record already on disk with a padded tag heals on load, so the fix
    /// reaches existing libraries without a migration.
    func testADirtyStoredRecordNeedsNoMigration() throws {
        let json = """
        {"id":"\(UUID().uuidString)","content":"x","createdAt":0,
         "tags":[{"name":"Work ","score":0.5},{"name":"work","score":0.9}]}
        """
        let decoded = try JSONDecoder().decode(
            TranscriptionRecord.self,
            from: Data(json.utf8)
        )
        let vm = makeViewModel([decoded])

        XCTAssertEqual(decoded.tagNames, ["Work", "work"])
        XCTAssertEqual(vm.availableTags, ["work"], "one chip, not two")
        vm.selectedTags = ["work"]
        XCTAssertEqual(vm.displayedRecords.count, 1)
    }

    // MARK: - Whitespace is invisible, so identity must ignore it

    func testIdentityIgnoresSurroundingWhitespace() {
        XCTAssertEqual(TagIdentity.key(" Work"), TagIdentity.key("work"))
        XCTAssertEqual(TagIdentity.normalized(" 工作 "), "工作")
    }

    /// Normalizing a whitespace-only tag yields an empty name, and an empty
    /// chip is an invisible pill the user cannot tap off. It must not render.
    func testAWhitespaceOnlyTagProducesNoChip() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "   ", score: 1.0)]),
            record("乙", tags: [TaggedItem(name: "工作", score: 0.5)])
        ])

        XCTAssertEqual(vm.availableTags, ["工作"])
    }

    func testAWhitespaceOnlyTagCannotInflateTheRelatedNotesScore() {
        let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let current = record(
            "甲",
            id: currentID,
            tags: [TaggedItem(name: "  ", score: 1.0), TaggedItem(name: "工作", score: 1.0)]
        )

        // A candidate carrying the same blank tag must not be credited with a
        // shared tag on that basis — the count feeds the score directly.
        let blankOnly = record("只有空标签", tags: [TaggedItem(name: " ", score: 1.0)])
        let realOverlap = record("真的共享", tags: [TaggedItem(name: "工作", score: 1.0)])

        let ranked = RelatedNotesService.prescreen(
            current: current,
            among: [blankOnly, realOverlap]
        )

        XCTAssertEqual(ranked.first?.id, realOverlap.id)
    }

    // MARK: - Vocabulary handed to the LLM

    func testVocabularyIsOrderedByHowOftenTheTagIsUsed() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "工作", score: 1.0), TaggedItem(name: "会议", score: 1.0)]),
            record("乙", tags: [TaggedItem(name: "工作", score: 1.0), TaggedItem(name: "会议", score: 1.0)]),
            record("丙", tags: [TaggedItem(name: "工作", score: 1.0)])
        ])

        XCTAssertEqual(vm.existingTagVocabulary, ["工作", "会议"])
    }

    /// Archived records' tags are just as worth reusing — the archive is
    /// storage, not a separate vocabulary.
    func testVocabularySpansTheWholeLibraryIncludingArchived() {
        let vm = makeViewModel([
            record("活的", tags: [TaggedItem(name: "工作", score: 1.0)]),
            record("收起的", tags: [TaggedItem(name: "旧项目", score: 1.0)], archived: true)
        ])

        XCTAssertEqual(vm.existingTagVocabulary, ["工作", "旧项目"])
    }

    func testVocabularyIsCappedAndSkipsBlanks() {
        let many = (0..<LLMService.maxTagVocabulary + 10).map { i in
            record("r\(i)", tags: [TaggedItem(name: "标签\(i)", score: 1.0)])
        }
        let vm = makeViewModel(many + [record("空", tags: [TaggedItem(name: "  ", score: 1.0)])])

        let vocabulary = vm.existingTagVocabulary

        XCTAssertEqual(vocabulary.count, LLMService.maxTagVocabulary)
        XCTAssertFalse(vocabulary.contains(""))
    }

    /// Casing is *not* unified in the vocabulary. The prompt asks the model to
    /// pick one spelling; folding case here would show it a tidy list while
    /// hiding the drift it is meant to notice.
    func testVocabularyKeepsCasingAsStored() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "Work", score: 1.0)]),
            record("乙", tags: [TaggedItem(name: "work", score: 1.0)])
        ])

        XCTAssertEqual(Set(vm.existingTagVocabulary), ["Work", "work"])
    }

    // MARK: - The prompt itself

    func testPromptWithoutVocabularyHasNoVocabularyBlock() {
        let prompt = LLMService.optimizeAndProcessPrompt(existingTagVocabulary: [])

        XCTAssertFalse(prompt.contains("【已有标签】"))
    }

    func testPromptWithVocabularyListsTheTags() {
        let prompt = LLMService.optimizeAndProcessPrompt(existingTagVocabulary: ["工作", "会议"])

        XCTAssertTrue(prompt.contains("【已有标签】"))
        XCTAssertTrue(prompt.contains("工作、会议"))
    }

    /// The vocabulary block is added *before* the format instruction, so a
    /// library with tags cannot accidentally teach the model a second output
    /// format. The 4-field schema is ADR-0002-locked.
    func testResponseSchemaIsUnchangedAndStillLast() throws {
        let prompt = LLMService.optimizeAndProcessPrompt(existingTagVocabulary: ["工作"])
        let schema = #"{"optimizedText": "...", "title": "...", "summary": "...", "tags": [{"name": "...", "score": 0.0}, ...]}"#

        let schemaRange = try XCTUnwrap(prompt.range(of: schema))
        let vocabRange = try XCTUnwrap(prompt.range(of: "【已有标签】"))

        XCTAssertLessThan(
            vocabRange.lowerBound, schemaRange.lowerBound,
            "the vocabulary block must not come after the format instruction"
        )
    }

    func testPromptStatesTheWhitespaceAndCasingRules() {
        let prompt = LLMService.optimizeAndProcessPrompt(existingTagVocabulary: [])

        XCTAssertTrue(prompt.contains("不要首尾空格"))
        XCTAssertTrue(prompt.contains("英文标签一律用小写"))
        XCTAssertTrue(prompt.contains("中文标签保持原样"))
    }

    /// The reuse instruction carries an anti-force-fit clause on purpose. An
    /// empty vocabulary is exactly when it is most tempting to over-apply.
    func testPromptWarnsAgainstForcingIrrelevantExistingTags() {
        let prompt = LLMService.optimizeAndProcessPrompt(existingTagVocabulary: ["工作"])

        XCTAssertTrue(prompt.contains("不要为了凑数"))
    }
}
