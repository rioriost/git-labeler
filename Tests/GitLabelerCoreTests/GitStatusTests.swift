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
        let environment = GitStatusReader.gitEnvironment(inheriting: [
            "PATH": "/usr/bin", "CUSTOM": "value", "GIT_OPTIONAL_LOCKS": "1",
            "GIT_CONFIG_GLOBAL": "/custom/gitconfig", "GIT_DIR": "/another/repo",
            "GIT_WORK_TREE": "/another/worktree", "GIT_COMMON_DIR": "/another/common",
            "GIT_INDEX_FILE": "/another/index", "GIT_OBJECT_DIRECTORY": "/another/objects",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/another/alternates",
            "GIT_CEILING_DIRECTORIES": "/", "GIT_PREFIX": "another/"
        ])

        XCTAssertEqual(environment["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["CUSTOM"], "value")
        XCTAssertEqual(environment["GIT_CONFIG_GLOBAL"], "/custom/gitconfig")
        for key in [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_CEILING_DIRECTORIES", "GIT_PREFIX"
        ] {
            XCTAssertNil(environment[key], key)
        }
    }

    func testOrdinaryDirectoryIsNotARepositoryAndDoesNotInvokeGit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let executable = try makeExecutable("exit 99", in: directory)
        let reader = try GitStatusReader(gitPath: executable.path)

        XCTAssertFalse(try reader.isRepositoryRoot(directory))
        XCTAssertNil(try reader.state(forRepositoryRoot: directory))
    }

    func testNestedDirectoryAndBareRepositoryAreNotRoots() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try runGit(["init", "--quiet"], at: directory)
        let nested = directory.appendingPathComponent("nested")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: false)
        let bare = directory.appendingPathComponent("bare.git")
        try runGit(["init", "--quiet", "--bare", bare.path], at: directory)
        let reader = try GitStatusReader()

        XCTAssertTrue(try reader.isRepositoryRoot(directory))
        XCTAssertFalse(try reader.isRepositoryRoot(nested))
        XCTAssertNil(try reader.state(forRepositoryRoot: nested))
        XCTAssertFalse(try reader.isRepositoryRoot(bare))
        XCTAssertNil(try reader.state(forRepositoryRoot: bare))
    }

    func testSymlinkAndWorktreeRoots() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try makeCommittedRepository(at: directory)
        let worktree = directory.appendingPathComponent("linked worktree")
        try runGit(["worktree", "add", "--quiet", "-b", "test-worktree", worktree.path], at: directory)
        let alias = directory.appendingPathComponent("alias")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: worktree)
        let reader = try GitStatusReader()

        XCTAssertTrue(try reader.isRepositoryRoot(worktree))
        XCTAssertTrue(try reader.isRepositoryRoot(alias))
        XCTAssertEqual(try reader.state(forRepositoryRoot: worktree), .clean)
        XCTAssertEqual(try reader.state(forRepositoryRoot: alias), .clean)
    }

    func testRootPathMayEndInWhitespace() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repository \n")
        try fileManager.createDirectory(at: repository, withIntermediateDirectories: false)
        try runGit(["init", "--quiet"], at: repository)

        XCTAssertTrue(try GitStatusReader().isRepositoryRoot(repository))
        XCTAssertEqual(try GitStatusReader().state(forRepositoryRoot: repository), .clean)
    }

    func testSubmoduleRootsAndIgnoredSubmoduleChangesAreDetected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let repository = directory.appendingPathComponent("repository")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: repository, withIntermediateDirectories: false)
        try makeCommittedRepository(at: source)
        try makeCommittedRepository(at: repository)
        try runGit([
            "-c", "protocol.file.allow=always", "submodule", "add", "--quiet", source.path, "module"
        ], at: repository)
        try commit(at: repository)
        try runGit(["config", "submodule.module.ignore", "all"], at: repository)
        try runGit(["config", "diff.ignoreSubmodules", "all"], at: repository)
        let module = repository.appendingPathComponent("module")
        let reader = try GitStatusReader()

        XCTAssertTrue(try reader.isRepositoryRoot(module))
        XCTAssertEqual(try reader.state(forRepositoryRoot: module), .clean)
        try Data("changed\n".utf8).write(to: module.appendingPathComponent("tracked.txt"))
        XCTAssertEqual(try reader.state(forRepositoryRoot: repository), .modified)
    }

    func testUntrackedFilesOverrideUserConfiguration() throws {
        let repository = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: repository) }
        try runGit(["init", "--quiet"], at: repository)
        try runGit(["config", "status.showUntrackedFiles", "no"], at: repository)
        let nested = repository.appendingPathComponent("new directory")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("new\n".utf8).write(to: nested.appendingPathComponent("new.txt"))

        XCTAssertEqual(try GitStatusReader().state(forRepositoryRoot: repository), .untracked)
    }

    func testCorruptRepositoryMetadataIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(
            at: directory.appendingPathComponent(".git"), withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try GitStatusReader().isRepositoryRoot(directory)) { error in
            guard case GitLabelerError.commandFailed(_, let status, let stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 128)
            XCTAssertFalse(stderr.isEmpty)
        }
    }

    func testBrokenWorktreeGitfileIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try Data("gitdir: nonexistent\n".utf8).write(to: directory.appendingPathComponent(".git"))

        XCTAssertThrowsError(try GitStatusReader().isRepositoryRoot(directory)) { error in
            guard case GitLabelerError.commandFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRootIdentityDoesNotReadCorruptIndex() throws {
        let repository = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: repository) }
        try makeCommittedRepository(at: repository)
        try Data("corrupt index".utf8).write(to: repository.appendingPathComponent(".git/index"))
        let reader = try GitStatusReader()

        XCTAssertTrue(try reader.isRepositoryRoot(repository))
        XCTAssertThrowsError(try reader.state(forRepositoryRoot: repository)) { error in
            guard case GitLabelerError.commandFailed(_, _, let stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(stderr.contains("index"))
        }
    }

    func testMissingExecutableIsAnActionableError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing-git")

        XCTAssertThrowsError(try GitStatusReader(gitPath: missing.path)) { error in
            guard case GitExecutionError.executionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains(missing.path))
        }
    }

    func testNonExecutableFileAndDirectoryAreRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let executable = try makeExecutable("exit 0", in: directory)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)

        for path in [executable.path, directory.path] {
            XCTAssertThrowsError(try GitStatusReader(gitPath: path)) { error in
                guard case GitExecutionError.executionFailed = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testInvalidExecutableLaunchIsNotTreatedAsANonRepository() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try runGit(["init", "--quiet"], at: directory)
        let executable = directory.appendingPathComponent("invalid-git")
        try Data("not an executable format\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let reader = try GitStatusReader(gitPath: executable.path)

        XCTAssertThrowsError(try reader.isRepositoryRoot(directory)) { error in
            guard case GitExecutionError.executionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("launching Git"))
        }
    }

    func testOperationalExit128IsPropagated() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try runGit(["init", "--quiet"], at: directory)
        let executable = try makeExecutable("printf 'fatal: Permission denied\\n' >&2\nexit 128", in: directory)

        XCTAssertThrowsError(try GitStatusReader(gitPath: executable.path).isRepositoryRoot(directory)) { error in
            guard case GitLabelerError.commandFailed(_, let status, let stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 128)
            XCTAssertTrue(stderr.contains("Permission denied"))
        }
    }

    func testUnreadableDirectoryIsAnError() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions") }
        let directory = try makeTemporaryDirectory()
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? fileManager.removeItem(at: directory)
        }
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)

        XCTAssertThrowsError(try GitStatusReader().isRepositoryRoot(directory)) { error in
            guard case GitExecutionError.repositoryInspectionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMissingDirectoryIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        XCTAssertThrowsError(try GitStatusReader().isRepositoryRoot(directory.appendingPathComponent("missing"))) {
            guard case GitExecutionError.repositoryInspectionFailed = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testBothOutputPipesAreDrainedDuringStderrFlood() throws {
        let result = try GitProcessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                i=0
                while [ "$i" -lt 1024 ]; do
                    printf '%s' "$1" >&2
                    printf '%s' "$1"
                    i=$((i + 1))
                done
                """,
                "fixture", String(repeating: "x", count: 1024)
            ],
            environment: GitStatusReader.gitEnvironment(), timeout: 5
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data(repeating: 120, count: 1_048_576))
        XCTAssertEqual(result.stderr, result.stdout)
    }

    func testTimeoutKillsAndReapsProcessIgnoringTermination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try runGit(["init", "--quiet"], at: directory)
        let executable = try makeExecutable(
            """
            trap '' TERM
            printf '%s' "$$" > "$2/git.pid"
            while :; do :; done
            """,
            in: directory
        )
        let reader = try GitStatusReader(gitPath: executable.path, timeout: 0.2)
        let start = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(try reader.isRepositoryRoot(directory)) { error in
            guard case GitExecutionError.timedOut(_, let timeout) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(timeout, 0.2)
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        try assertProcessesExited(recordedAt: directory.appendingPathComponent("git.pid"))
    }

    func testTimeoutBoundsInheritedPipeDescriptorsAndTerminatesDescendant() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pids")
        let start = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(try GitProcessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                /bin/sleep 30 &
                printf '%s %s' "$$" "$!" > "$1"
                exit 0
                """,
                "fixture", pidFile.path
            ],
            environment: GitStatusReader.gitEnvironment(), timeout: 0.2
        )) { error in
            guard case GitExecutionError.timedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        try assertProcessesExited(recordedAt: pidFile)
    }

    func testTimeoutStillAppliesAfterProcessClosesBothOutputs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let start = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(try GitProcessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                trap '' TERM
                printf '%s' "$$" > "$1"
                exec 1>&- 2>&-
                while :; do :; done
                """,
                "fixture", pidFile.path
            ],
            environment: GitStatusReader.gitEnvironment(), timeout: 0.2
        )) { error in
            guard case GitExecutionError.timedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        try assertProcessesExited(recordedAt: pidFile)
    }

    func testSuccessfulCommandDoesNotLeaveAHelperWithClosedOutputs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pids")
        let result = try GitProcessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                /bin/sleep 30 >/dev/null 2>&1 &
                printf '%s %s' "$$" "$!" > "$1"
                exit 0
                """,
                "fixture", pidFile.path
            ],
            environment: GitStatusReader.gitEnvironment(), timeout: 2
        )

        XCTAssertEqual(result.status, 0)
        try assertProcessesExited(recordedAt: pidFile)
    }

    func testInvalidTimeoutIsRejected() {
        for timeout: TimeInterval in [0, -1, .infinity, .nan] {
            XCTAssertThrowsError(try GitStatusReader(timeout: timeout)) { error in
                guard case GitExecutionError.invalidTimeout = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
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
        let indexData = try Data(contentsOf: indexURL)
        let indexModificationTime = try fileManager.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date

        let state = try GitStatusReader().state(forRepositoryRoot: repository)

        XCTAssertEqual(state, .clean)
        XCTAssertEqual(try statusChangeTime(for: indexURL), indexChangeTime)
        XCTAssertEqual(try Data(contentsOf: indexURL), indexData)
        XCTAssertEqual(
            try fileManager.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date,
            indexModificationTime
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = project
            .appendingPathComponent(".git-labeler-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func makeExecutable(_ script: String, in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("fake-git")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func makeCommittedRepository(at directory: URL) throws {
        try runGit(["init", "--quiet"], at: directory)
        try Data("tracked\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        try runGit(["add", "tracked.txt"], at: directory)
        try commit(at: directory)
    }

    private func commit(at directory: URL) throws {
        try runGit([
            "-c", "user.name=Git Labeler Tests",
            "-c", "user.email=git-labeler@example.invalid",
            "-c", "commit.gpgsign=false",
            "commit", "--quiet", "-m", "test"
        ], at: directory)
    }

    private func assertProcessesExited(recordedAt file: URL, fileID: StaticString = #filePath, line: UInt = #line) throws {
        let pids = try String(contentsOf: file, encoding: .utf8)
            .split(separator: " ").compactMap { pid_t($0) }
        XCTAssertFalse(pids.isEmpty, file: fileID, line: line)
        for pid in pids {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while kill(pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let result = kill(pid, 0)
            let error = errno
            XCTAssertEqual(result, -1, "Process \(pid) is still present", file: fileID, line: line)
            XCTAssertEqual(error, ESRCH, file: fileID, line: line)
        }
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = GitStatusReader.gitEnvironment()
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
