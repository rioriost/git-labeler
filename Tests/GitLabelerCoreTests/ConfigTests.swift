import Foundation
import XCTest
@testable import GitLabelerCore

final class ConfigTests: XCTestCase {
    func testDefaultsAreValid() throws {
        try GitLabelerConfig().validate()
    }

    func testRejectsUnsupportedVersionAndInvalidIntervals() {
        let invalid = [
            GitLabelerConfig(version: 999),
            GitLabelerConfig(debounceMilliseconds: -1),
            GitLabelerConfig(debounceMilliseconds: 60_001),
            GitLabelerConfig(rescanIntervalSeconds: 0),
            GitLabelerConfig(rescanIntervalSeconds: -1),
            GitLabelerConfig(rescanIntervalSeconds: Int.max)
        ]
        for config in invalid {
            XCTAssertThrowsError(try config.validate())
            XCTAssertThrowsError(try GitLabelerDaemon(config: config))
            XCTAssertThrowsError(try RepoScanner(config: config))
        }
    }

    func testAcceptsIntervalBoundaries() throws {
        try GitLabelerConfig(debounceMilliseconds: 0, rescanIntervalSeconds: 1).validate()
        try GitLabelerConfig(debounceMilliseconds: 60_000, rescanIntervalSeconds: 86_400).validate()
    }

    func testRootsMustBeAbsoluteButCanBeTemporarilyMissing() throws {
        XCTAssertThrowsError(try GitLabelerConfig(roots: ["relative"]).validate())
        XCTAssertThrowsError(try GitLabelerConfig(roots: ["/invalid\0path"]).validate())
        try GitLabelerConfig(roots: ["/missing-\(UUID().uuidString)"]).validate()
    }

    func testRejectsInvalidGitPath() throws {
        for path in ["", "git", "/missing-\(UUID().uuidString)", "/usr/bin"] {
            XCTAssertThrowsError(try GitLabelerConfig(gitPath: path).validate())
        }
        try GitLabelerConfig(gitPath: "/usr/bin/git").validate()
    }

    func testRejectsEmptyAmbiguousAndControlCharacterTagNames() {
        for name in ["", "  ", "tag\n2", "tag\0name"] {
            XCTAssertThrowsError(
                try GitLabelerConfig(tags: .init(untracked: name)).validate()
            )
        }
        XCTAssertThrowsError(
            try GitLabelerConfig(tags: .init(untracked: "same", modified: "same")).validate()
        )
    }

    func testLoadValidatesAndFailedSavePreservesExistingConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(url: directory.appendingPathComponent("config.json"))
        try store.save(GitLabelerConfig())
        let original = try Data(contentsOf: store.url)
        let invalid = GitLabelerConfig(rescanIntervalSeconds: 0)
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: store.url), original)

        try JSONEncoder().encode(invalid).write(to: store.url)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("rescanIntervalSeconds"))
        }
    }
}
