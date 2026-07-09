import Foundation
import XCTest
@testable import GitLabelerCore

final class GitStatusTests: XCTestCase {
    func testParsesCleanStatus() {
        XCTAssertEqual(GitStatusReader.parsePorcelainStatus(Data()), .clean)
    }

    func testParsesUntrackedStatus() {
        let data = Data("?? new-file\u{0}".utf8)
        XCTAssertEqual(GitStatusReader.parsePorcelainStatus(data), .untracked)
    }

    func testModifiedBeatsUntracked() {
        let data = Data("?? new-file\u{0} M changed.swift\u{0}".utf8)
        XCTAssertEqual(GitStatusReader.parsePorcelainStatus(data), .modified)
    }

    func testDeletedBeatsModified() {
        let data = Data(" M changed.swift\u{0} D removed.swift\u{0}".utf8)
        XCTAssertEqual(GitStatusReader.parsePorcelainStatus(data), .deleted)
    }

    func testRenameExtraPathIsSkipped() {
        let data = Data("R  new-name.swift\u{0}DeletedLookingOldName.swift\u{0}".utf8)
        XCTAssertEqual(GitStatusReader.parsePorcelainStatus(data), .modified)
    }
}
