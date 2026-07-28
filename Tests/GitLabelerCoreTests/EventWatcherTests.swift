import Foundation
import XCTest
@testable import GitLabelerCore

final class EventWatcherTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/git-labeler-root", isDirectory: true)

    func testIgnoresFsmonitorDaemonEvents() {
        let watcher = makeWatcher()

        XCTAssertNil(
            watcher.repositoryCandidate(
                for: root.appendingPathComponent("repo/.git/fsmonitor--daemon", isDirectory: true)
            )
        )
        XCTAssertNil(
            watcher.repositoryCandidate(
                for: root.appendingPathComponent(
                    "repo/.git/fsmonitor--daemon/cookies/cookie-1",
                    isDirectory: false
                )
            )
        )
        XCTAssertNil(
            watcher.repositoryCandidate(
                for: root.appendingPathComponent("repo/.git/fsmonitor--daemon/ipc", isDirectory: false)
            )
        )
    }

    func testPreservesOtherRepositoryEvents() {
        let watcher = makeWatcher()
        let repository = root.appendingPathComponent("repo", isDirectory: true)

        XCTAssertEqual(
            watcher.repositoryCandidate(
                for: root.appendingPathComponent("repo/.git/index", isDirectory: false)
            ),
            repository
        )
        XCTAssertEqual(
            watcher.repositoryCandidate(
                for: root.appendingPathComponent("repo/.gitignore", isDirectory: false)
            ),
            repository
        )
        XCTAssertEqual(
            watcher.repositoryCandidate(
                for: root.appendingPathComponent("repo/Sources/App.swift", isDirectory: false)
            ),
            repository
        )
    }

    private func makeWatcher() -> EventWatcher {
        EventWatcher(roots: [root]) { _ in }
    }
}
