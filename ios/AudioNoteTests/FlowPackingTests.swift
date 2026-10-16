import XCTest
@testable import AudioNote

/// The packing half of `FlowRow`. The `Layout` conformance on top is
/// placement only — it re-reads these lines and walks them — so this is
/// where the behaviour is pinned.
final class FlowPackingTests: XCTestCase {

    private func sizes(_ widths: [CGFloat], height: CGFloat = 32) -> [CGSize] {
        widths.map { CGSize(width: $0, height: height) }
    }

    func testEverythingThatFitsStaysOnOneLine() {
        let lines = FlowPacking.lines(sizes: sizes([50, 60, 70]), maxWidth: 300, spacing: 8)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].indices, [0, 1, 2])
    }

    func testWrapsOnceTheRowIsFull() {
        // 50 + 8 + 60 = 118; adding 70 would need 196, over 150.
        let lines = FlowPacking.lines(sizes: sizes([50, 60, 70]), maxWidth: 150, spacing: 8)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].indices, [0, 1])
        XCTAssertEqual(lines[1].indices, [2])
    }

    /// `Line.width` is what the line occupies, with no trailing gap. If it
    /// carried one, every line would over-report by `spacing` and a line
    /// could be judged as overflowing when it exactly fills the row.
    func testLineWidthHasNoTrailingGap() {
        let lines = FlowPacking.lines(sizes: sizes([50, 60]), maxWidth: 300, spacing: 8)

        XCTAssertEqual(lines[0].width, 118)
    }

    func testExactFitDoesNotWrap() {
        // 50 + 8 + 60 = 118 exactly.
        let lines = FlowPacking.lines(sizes: sizes([50, 60]), maxWidth: 118, spacing: 8)

        XCTAssertEqual(lines.count, 1, "a row that fits exactly must not push its last tile down")
    }

    func testOnePointOverExactFitWraps() {
        let lines = FlowPacking.lines(sizes: sizes([50, 60]), maxWidth: 117.9, spacing: 8)

        XCTAssertEqual(lines.count, 2)
    }

    /// The one input with no good alternative: user-supplied tag text can
    /// exceed the screen width. It gets its own line and overflows visibly
    /// — the alternative (dropping it, or re-testing it forever) is worse.
    func testOversizedItemGetsItsOwnLineRatherThanLooping() {
        let lines = FlowPacking.lines(sizes: sizes([50, 500, 60]), maxWidth: 150, spacing: 8)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map(\.indices), [[0], [1], [2]])
    }

    func testLineHeightIsTheTallestItemOnIt() {
        var mixed = sizes([50, 60, 70])
        mixed[1].height = 44

        let lines = FlowPacking.lines(sizes: mixed, maxWidth: 150, spacing: 8)

        XCTAssertEqual(lines[0].height, 44)
        XCTAssertEqual(lines[1].height, 32)
    }

    func testEmptyInputProducesNoLines() {
        XCTAssertTrue(FlowPacking.lines(sizes: [], maxWidth: 300, spacing: 8).isEmpty)
    }

    /// `.unspecified` width arrives here as infinity — the flow is being
    /// asked how tall it would be, not how it should be laid out.
    func testInfiniteWidthKeepsEverythingOnOneLine() {
        let lines = FlowPacking.lines(sizes: sizes([50, 60, 70]), maxWidth: .infinity, spacing: 8)

        XCTAssertEqual(lines.count, 1)
    }

    func testZeroSpacingStillFitsBothItems() {
        let lines = FlowPacking.lines(sizes: sizes([50, 60]), maxWidth: 110, spacing: 0)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].width, 110)
    }

    /// Every item lands on exactly one line — no index dropped, none placed
    /// twice. A view builder that silently loses a tag would present a merge
    /// list missing a tag the user can see on the chip row.
    func testEveryIndexAppearsExactlyOnceAcrossAllLines() {
        let lines = FlowPacking.lines(
            sizes: sizes([50, 200, 60, 40, 300, 70, 20]),
            maxWidth: 180,
            spacing: 8
        )

        let placed = lines.flatMap(\.indices).sorted()
        XCTAssertEqual(placed, Array(0..<7))
    }
}
