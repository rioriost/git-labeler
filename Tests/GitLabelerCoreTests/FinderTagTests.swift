import XCTest
@testable import GitLabelerCore

final class FinderTagTests: XCTestCase {
    func testDecodesColoredTag() {
        XCTAssertEqual(FinderTag.decode("git:deleted\n6"), FinderTag(name: "git:deleted", color: 6))
    }

    func testDecodesPlainTag() {
        XCTAssertEqual(FinderTag.decode("important"), FinderTag(name: "important"))
    }

    func testEncodesColoredTag() {
        XCTAssertEqual(FinderTag(name: "git:modified", color: 5).encodedValue, "git:modified\n5")
    }
}
