import XCTest
@testable import AudioNote

final class RelatedNotesSanitizeTests: XCTestCase {

    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
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
        // Ruling O: the storage layer does not guard self-edges, so a
        // hallucinated self-match would persist and eat a display slot.
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

    // MARK: - Dedupe before cap

    func testDedupeRunsBeforeTheCapSoADuplicateCannotEatASlot() {
        // 7 distinct ids, 2 of them repeated. The duplicates sit at ranks 2
        // and 4, i.e. exactly where capping first would spend two of the five
        // display slots on the same note twice.
        let ids = (0..<7).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        let input: [RelatedNoteMatch] = [
            RelatedNoteMatch(id: ids[0], score: 0.90),
            RelatedNoteMatch(id: ids[0], score: 0.85),   // duplicate
            RelatedNoteMatch(id: ids[1], score: 0.80),
            RelatedNoteMatch(id: ids[1], score: 0.78),   // duplicate
            RelatedNoteMatch(id: ids[2], score: 0.70),
            RelatedNoteMatch(id: ids[3], score: 0.60),
            RelatedNoteMatch(id: ids[4], score: 0.50),
            RelatedNoteMatch(id: ids[5], score: 0.40),
            RelatedNoteMatch(id: ids[6], score: 0.30),
        ]

        let out = RelatedNotesService.sanitize(input, candidateIDs: Set(ids), currentID: UUID())
        let outIDs = out.map(\.id)

        XCTAssertEqual(out.count, RelatedNotesService.maxRelated)
        XCTAssertEqual(Set(outIDs).count, RelatedNotesService.maxRelated, "no id may take two display slots")
        XCTAssertEqual(outIDs, Array(ids[0...4]), "the two freed slots must go to real entries, not to repeats")
        XCTAssertTrue(outIDs.contains(ids[4]))
        XCTAssertFalse(outIDs.contains(ids[5]), "ids[4] and ids[5] only reach the list if the duplicates were removed first")
    }

    // MARK: - Deterministic tie-break

    func testEqualScoresFollowTheModelsOrderForEveryRotationOfTheSameIdSet() {
        // spec §4.3/§4.4: a stored list must not reshuffle between app
        // launches, and Dictionary iteration order is seeded per process. So
        // a tie on score is broken by first appearance in the model's list,
        // not by hash order. `maxRelated` ids, all tied, so the whole output
        // is decided by the tie-break and nothing is left to the cap.
        //
        // One order is not enough. An implementation that fell back to hash
        // order would still answer this correctly whenever the seeded order
        // happened to coincide with the one order asserted here — measured at
        // ~1.4% of process launches (17/1200), a false PASS, i.e. CI green
        // over a broken guarantee. So the id set is held fixed and all
        // `maxRelated` cyclic rotations of it are asserted, and the suite
        // also pins that repeated calls on one input agree with each other.
        //
        // Together those two make the test seed-independent rather than
        // merely unlikely-to-false-pass. Suppose the tie-break were dropped:
        // the output is then one fixed permutation, the same for every call
        // (same key set, same process seed) — call that P. Passing now needs
        // P to equal all 5 rotations at once, and 5 distinct rotations are
        // pairwise distinct permutations, so P can match at most one of
        // them: the test fails for every seed. The only way out would be an
        // implementation whose output varies between two calls on the *same*
        // input, and that is precisely what the repeat call rejects. A single
        // asserted order established determinism and the specific order at
        // the same time; only the second one was really there.
        let ids = (0..<RelatedNotesService.maxRelated)
            .map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }

        let candidateIDs = Set(ids)
        for rotation in 0..<RelatedNotesService.maxRelated {
            let modelOrder: [UUID] = Array(ids[rotation...] + ids[..<rotation])
            let input = modelOrder.map { RelatedNoteMatch(id: $0, score: 0.5) }

            let out = RelatedNotesService.sanitize(input, candidateIDs: candidateIDs, currentID: UUID())
            let outIDs = out.map(\.id)
            XCTAssertEqual(outIDs.count, RelatedNotesService.maxRelated)
            XCTAssertEqual(
                outIDs, modelOrder,
                "rotation \(rotation): a full tie must fall back to the model's own order, not to hash order"
            )

            let again = RelatedNotesService.sanitize(input, candidateIDs: candidateIDs, currentID: UUID())
            XCTAssertEqual(
                again.map(\.id), outIDs,
                "rotation \(rotation): the same input must not render in a different order on a second call"
            )
        }
    }

    // MARK: - Non-positive scores

    func testDropsNonPositiveScoresInsteadOfClampingThemToZero() {
        // A negative or zero score is the model saying "not related" with a
        // broken number. Both are far below `minimumScore` so neither can
        // reach a display slot — but clamping would persist 0.0, a value the
        // model never wrote, and the stored edge would disagree with the
        // reply it came from.
        let input = [
            RelatedNoteMatch(id: a, score: -0.5),
            RelatedNoteMatch(id: b, score: 0.0),
        ]
        XCTAssertTrue(
            RelatedNotesService.sanitize(input, candidateIDs: [a, b], currentID: UUID()).isEmpty
        )

        let mixed = [
            RelatedNoteMatch(id: a, score: -0.5),
            RelatedNoteMatch(id: b, score: 0.8),
        ]
        let out = RelatedNotesService.sanitize(mixed, candidateIDs: [a, b], currentID: UUID())
        XCTAssertEqual(out.map(\.id), [b], "dropping the non-positive score must not take its neighbour with it")
        XCTAssertEqual(out.first?.score ?? 0, 0.8, accuracy: 0.0001)
    }
}
