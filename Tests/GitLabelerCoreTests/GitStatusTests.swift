import Foundation
import XCTest
@testable import GitLabelerCore

final class GitStatusTests: XCTestCase {
    private let fileManager = FileManager.default

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

    func testGitEnvironmentDisablesOptionalLocksAndPreservesExistingValues() {
        let environment = GitStatusReader.gitEnvironment(inheriting: ["PATH": "/usr/bin", "CUSTOM": "value"])

        XCTAssertEqual(environment["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["CUSTOM"], "value")
    }

    func testStatusDoesNotRefreshIndexStatCache() throws {
        let repository = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: repository) }

        try runGit(["init", "--quiet"], at: repository)
        let trackedFile = repository.appendingPathComponent("tracked.txt")
        try Data("tracked\n".utf8).write(to: trackedFile)
        try runGit(["add", "tracked.txt"], at: repository)
        try runGit([
            "-c", "user.name=Git Labeler Tests",
            "-c", "user.email=git-labeler@example.invalid",
            "commit", "--quiet", "-m", "initial"
        ], at: repository)

        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: trackedFile.path
        )
        let indexURL = repository.appendingPathComponent(".git/index")
        let indexChangeTime = try statusChangeTime(for: indexURL)

        let state = try GitStatusReader().state(forRepositoryRoot: repository)

        XCTAssertEqual(state, .clean)
        XCTAssertEqual(try statusChangeTime(for: indexURL), indexChangeTime)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitLabelerError.commandFailed(
                command: arguments.joined(separator: " "),
                status: process.terminationStatus,
                stderr: ""
            )
        }
    }

    private func statusChangeTime(for url: URL) throws -> [Int] {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return [Int(status.st_ctimespec.tv_sec), Int(status.st_ctimespec.tv_nsec)]
    }
}
