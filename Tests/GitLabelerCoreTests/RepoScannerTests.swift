import Foundation
import XCTest
@testable import GitLabelerCore

final class RepoScannerTests: XCTestCase {
    func testFileAndDisappearedEventCandidatesAreIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)
        let scanner = try RepoScanner(config: GitLabelerConfig())
        for candidate in [file, directory.appendingPathComponent("removed")] {
            let result = scanner.scanRepositoryCandidate(candidate)
            XCTAssertNil(result.state)
            XCTAssertNil(result.errorDescription)
            let clear = scanner.clearRepositoryCandidate(candidate)
            XCTAssertFalse(clear.cleared)
            XCTAssertNil(clear.errorDescription)
        }
    }

    func testClearOnlyChecksRepositoryIdentityAndPreservesUserTags() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--quiet", directory.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let wrapper = directory.appendingPathComponent("git-wrapper")
        try Data("""
        #!/bin/sh
        if [ "$3" = status ]; then
          echo "status must not run during clear" >&2
          exit 88
        fi
        exec /usr/bin/git "$@"

        """.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let tagger = FinderTagger()
        try tagger.apply(state: .modified, to: directory, tagNames: .init(modified: "personal"))
        try tagger.apply(state: .untracked, to: directory, tagNames: .init())
        let scanner = try RepoScanner(config: GitLabelerConfig(gitPath: wrapper.path))

        let result = scanner.clearRepositoryCandidate(directory)
        XCTAssertTrue(result.cleared)
        XCTAssertNil(result.errorDescription)
        XCTAssertEqual(try tagger.readTags(from: directory), [FinderTag(name: "personal", color: 5)])
    }
}
