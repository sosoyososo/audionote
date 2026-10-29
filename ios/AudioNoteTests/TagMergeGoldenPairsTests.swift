import XCTest
@testable import AudioNote

/// The pairs a human would merge, pinned as a fixture.
///
/// The model found these five on its own when it was shown the whole
/// vocabulary, so they are known-good. The candidate grouping has to put
/// every one of them in front of the model — a grouping that drops them
/// leaves the model with nothing to merge, and it says so.
final class TagMergeGoldenPairsTests: XCTestCase {

    /// The pairs that should be mergeable, with the tag that should survive.
    private static let golden: [(target: String, source: String)] = [
        ("功能测试", "测试验证"),
        ("语音笔记", "语音转录"),
        ("语音笔记", "AI语音"),
        ("交互设计", "人机交互"),
        ("数据持久化", "数据存储"),
        ("笔记相关度", "笔记关联"),
        ("用户反馈", "产品反馈"),
        ("用户反馈", "功能反馈"),
        ("用户反馈", "Bug反馈")
    ]

    func testEveryKnownPairReachesTheModel() {
        let counts = [
            "功能测试": 7, "测试验证": 4, "语音笔记": 9, "语音转录": 7, "AI语音": 3,
            "交互设计": 6, "人机交互": 1, "数据持久化": 2, "数据存储": 1,
            "笔记相关度": 3, "笔记关联": 1, "用户反馈": 2, "产品反馈": 2,
            "功能反馈": 1, "Bug反馈": 2
        ]

        let groups = TagMergeCandidates.groups(counts: counts)

        for pair in Self.golden {
            let together = groups.contains { group in
                group.contains(pair.target) && group.contains(pair.source)
            }
            XCTAssertTrue(
                together,
                "\(pair.source) and \(pair.target) never reach the model together"
            )
        }
    }

    func testTheHeadSurvivesTheCap() {
        // The head is where reuse pays off, and it must not be the thing
        // the cap cuts.
        var counts: [String: Int] = [:]
        for index in 0..<200 {
            counts["标签\\(index)"] = index
        }
        counts["功能测试"] = 900
        counts["测试验证"] = 400

        let groups = TagMergeCandidates.groups(counts: counts, maxGroups: 3)

        XCTAssertTrue(groups.contains { $0.contains("功能测试") })
    }
}
