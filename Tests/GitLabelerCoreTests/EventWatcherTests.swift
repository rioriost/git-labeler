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

    func testNestedRootsProduceAllRelevantCandidatesWithoutDuplicates() {
        let inner = root.appendingPathComponent("group", isDirectory: true)
        let watcher = EventWatcher(roots: [root, inner, inner]) { _ in }
        XCTAssertEqual(
            watcher.repositoryCandidates(for: inner.appendingPathComponent("repo/file")),
            [inner, inner.appendingPathComponent("repo", isDirectory: true)]
        )
    }

    func testRootEventsDoNotPreventOtherRootsFromMatching() {
        let inner = root.appendingPathComponent("group", isDirectory: true)
        let watcher = EventWatcher(roots: [inner, root]) { _ in }
        XCTAssertEqual(watcher.repositoryCandidates(for: inner), [inner])
    }

    func testUnrelatedAndPrefixSiblingPathsAreIgnored() {
        let watcher = makeWatcher()
        XCTAssertEqual(watcher.repositoryCandidates(for: root), [])
        XCTAssertEqual(
            watcher.repositoryCandidates(for: URL(fileURLWithPath: root.path + "-other/repo/file")),
            []
        )
    }

    func testFilesystemRootUsesSingleSlashPrefix() {
        let watcher = EventWatcher(roots: [URL(fileURLWithPath: "/")]) { _ in }
        XCTAssertEqual(
            watcher.repositoryCandidates(for: URL(fileURLWithPath: "/Users/example/file")),
            [URL(fileURLWithPath: "/Users", isDirectory: true)]
        )
    }

    func testDebouncerCoalescesEvents() {
        let completed = expectation(description: "one scan")
        completed.assertForOverFulfill = true
        let debouncer = RepositoryDebouncer(milliseconds: 40) { _ in completed.fulfill() }
        for _ in 0..<20 {
            debouncer.schedule(root)
        }
        wait(for: [completed], timeout: 2)
        withExtendedLifetime(debouncer) {}
    }

    func testEventAndPeriodicWorkUseTheSameSerialQueue() {
        let queue = DispatchQueue(label: "git-labeler.tests.scan")
        let periodicStarted = DispatchSemaphore(value: 0)
        let finishPeriodic = DispatchSemaphore(value: 0)
        let eventStarted = DispatchSemaphore(value: 0)
        let completed = expectation(description: "event scan")
        let debouncer = RepositoryDebouncer(milliseconds: 0, queue: queue) { _ in
            eventStarted.signal()
            completed.fulfill()
        }
        queue.async {
            periodicStarted.signal()
            _ = finishPeriodic.wait(timeout: .now() + 2)
        }
        XCTAssertEqual(periodicStarted.wait(timeout: .now() + 2), .success)
        debouncer.schedule(root)
        XCTAssertEqual(eventStarted.wait(timeout: .now() + 0.05), .timedOut)
        finishPeriodic.signal()
        wait(for: [completed], timeout: 2)
        withExtendedLifetime(debouncer) {}
    }

    private func makeWatcher() -> EventWatcher {
        EventWatcher(roots: [root]) { _ in }
    }
}
