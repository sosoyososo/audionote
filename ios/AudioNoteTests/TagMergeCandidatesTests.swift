import XCTest
@testable import AudioNote

/// Choosing which tags the model is asked about.
///
/// The point of the whole thing is that the model reasons out loud, and
/// most of that reasoning was spent ruling out tags that obviously did not
/// belong together. These tests pin what gets sent: the groups that
/// resemble each other, without the transitive chaining that would put
/// seventy unrelated tags in one group.
final class TagMergeCandidatesTests: XCTestCase {

    func testTagsSharingAWordEndUpTogether() {
        let groups = TagMergeCandidates.groups(counts: ["功能测试": 9, "测试验证": 4, "语音笔记": 9])

        XCTAssertTrue(groups.contains { $0.contains("功能测试") && $0.contains("测试验证") })
    }

    func testGroupingIsNotTransitive() {
        // 功能反馈 shares 功能 with 功能优化, and 反馈 with 用户反馈 — but
        // 功能优化 and 用户反馈 share nothing. A transitive clustering puts
        // all three in one group; grouping by the shared substring does not.
        let groups = TagMergeCandidates.groups(counts: ["功能反馈": 1, "用户反馈": 1, "功能优化": 1])

        // The last group is the head — the most-used tags, offered together
        // so that a pure synonym (which shares no characters with anything)
        // can still be found. It is meant to hold unrelated tags.
        for group in groups.dropLast() {
            XCTAssertFalse(group.contains("功能优化") && group.contains("用户反馈"))
        }
        // The two pairs that do share something are each offered.
        XCTAssertTrue(groups.contains { $0.contains("功能反馈") && $0.contains("功能优化") })
        XCTAssertTrue(groups.contains { $0.contains("功能反馈") && $0.contains("用户反馈") })
    }

    func testAGroupOfOneIsNotOffered() {
        let groups = TagMergeCandidates.groups(counts: ["语音笔记": 9, "数据分析": 2])

        // "数据分析" has no partner, so only the head group survives.
        for group in groups {
            XCTAssertGreaterThan(group.count, 1)
        }
    }

    func testTheMostUsedTagsAreIncludedEvenWithoutAPartner() {
        // 会议 and 研讨 are the same thing and share no characters, so a
        // pure-similarity filter would never show them to anyone.
        let groups = TagMergeCandidates.groups(counts: ["会议": 20, "研讨": 5, "完全无关": 1])

        XCTAssertTrue(groups.contains { $0.contains("会议") && $0.contains("研讨") })
    }

    func testATagMayAppearInMoreThanOneGroup() {
        // 笔记相关度 belongs with 笔记关联 (they share 笔记) and with
        // 相关度计算 (they share 相关度). Both are worth showing.
        let groups = TagMergeCandidates.groups(counts: ["笔记相关度": 3, "笔记关联": 1, "相关度计算": 1])

        XCTAssertTrue(groups.contains { $0.contains("笔记相关度") && $0.contains("笔记关联") })
        XCTAssertTrue(groups.contains { $0.contains("笔记相关度") && $0.contains("相关度计算") })
    }

    func testLatinTagsMatchOnWholeWords() {
        let groups = TagMergeCandidates.groups(counts: ["work": 5, "workflow": 2, "build": 1])

        XCTAssertTrue(groups.contains { $0.contains("work") && $0.contains("workflow") })
    }

    func testASingleCharacterIsNotEnoughToLink() {
        // 会 is in half the library; one shared character would link
        // everything to everything.
        let groups = TagMergeCandidates.groups(counts: ["会议": 5, "机会": 3, "体会": 2], headSize: 0)

        for group in groups {
            XCTAssertGreaterThan(group.count, 1)
        }
    }

    func testEmptyInputIsSafe() {
        XCTAssertTrue(TagMergeCandidates.groups(counts: [:]).isEmpty)
    }

    func testTheSharedKeysOfATag() {
        XCTAssertTrue(TagMergeCandidates.sharedKeys(of: "会议纪要").contains("会议"))
        XCTAssertTrue(TagMergeCandidates.sharedKeys(of: "Build in Public").contains("build"))
        // A two-letter Latin word is too weak: "ai" sits inside "daily".
        XCTAssertFalse(TagMergeCandidates.sharedKeys(of: "daily").contains("ai"))
    }
}
