import Foundation
import Darwin

public enum GitExecutionError: Error, LocalizedError, Equatable {
    case invalidTimeout(TimeInterval)
    case executionFailed(command: String, reason: String)
    case timedOut(command: String, timeout: TimeInterval)
    case repositoryInspectionFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            return "Git command timeout must be a finite, positive number of seconds"
        case .executionFailed(let command, let reason):
            return "could not execute \(command): \(reason); check the Git executable and its permissions"
        case .timedOut(let command, let timeout):
            return "\(command) timed out after \(timeout) seconds; check the repository and Git helpers"
        case .repositoryInspectionFailed(let path, let reason):
            return "could not inspect repository at \(path): \(reason); check its permissions and Git metadata"
        }
    }
}

public enum RepositoryState: String, Codable, Equatable, Comparable {
    case clean
    case untracked
    case modified
    case deleted

    private var rank: Int {
        switch self {
        case .clean: return 0
        case .untracked: return 1
        case .modified: return 2
        case .deleted: return 3
        }
    }

    public static func < (lhs: RepositoryState, rhs: RepositoryState) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct GitStatusReader {
    private let gitPath: String
    private let timeout: TimeInterval

    public init(gitPath: String? = nil, timeout: TimeInterval = 30) throws {
        guard timeout.isFinite, timeout > 0 else {
            throw GitExecutionError.invalidTimeout(timeout)
        }
        self.timeout = timeout
        if let gitPath, !gitPath.isEmpty {
            self.gitPath = URL(fileURLWithPath: gitPath).path
        } else if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git") {
            self.gitPath = "/opt/homebrew/bin/git"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            self.gitPath = "/usr/bin/git"
        } else {
            throw GitLabelerError.gitNotFound
        }

        var metadata = stat()
        guard stat(self.gitPath, &metadata) == 0, access(self.gitPath, X_OK) == 0 else {
            throw GitExecutionError.executionFailed(
                command: self.gitPath, reason: String(cString: strerror(errno))
            )
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw GitExecutionError.executionFailed(
                command: self.gitPath, reason: "Git executable is not a regular file"
            )
        }
    }

    public func state(forRepositoryRoot repositoryURL: URL) throws -> RepositoryState? {
        guard try isRepositoryRoot(repositoryURL) else {
            return nil
        }

        let data = try runGit(arguments: [
            "status",
            "--porcelain=v1",
            "--untracked-files=normal",
            "--ignore-submodules=none",
            "-z"
        ], at: repositoryURL).stdout

        return Self.parsePorcelainStatus(data)
    }

    public static func parsePorcelainStatus(_ data: Data) -> RepositoryState {
        guard !data.isEmpty else {
            return .clean
        }

        var state = RepositoryState.clean
        let entries = data.split(separator: 0, omittingEmptySubsequences: true)
        var index = entries.startIndex

        while index < entries.endIndex {
            let entry = entries[index]
            index = entries.index(after: index)
            guard entry.count >= 2 else {
                continue
            }

            let x = entry[entry.startIndex]
            let y = entry[entry.index(after: entry.startIndex)]

            if x == ascii("D") || y == ascii("D") {
                return .deleted
            }

            if x == ascii("?") && y == ascii("?") {
                state = max(state, .untracked)
                continue
            }

            if x != ascii(" ") || y != ascii(" ") {
                state = max(state, .modified)
            }

            if x == ascii("R") || y == ascii("R") || x == ascii("C") || y == ascii("C") {
                if index < entries.endIndex {
                    index = entries.index(after: index)
                }
            }
        }

        return state
    }

    /// Checks root identity without running status or inspecting the index.
    /// Ordinary directories and bare repositories return false; operational failures throw.
    public func isRepositoryRoot(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard stat(url.path, &metadata) == 0, access(url.path, R_OK | X_OK) == 0 else {
            throw GitExecutionError.repositoryInspectionFailed(
                path: url.path, reason: String(cString: strerror(errno))
            )
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw GitLabelerError.invalidDirectory(url.path)
        }

        // Root worktrees and submodules have a direct .git directory or gitfile.
        // Checking metadata distinguishes an ordinary non-repository from a broken one
        // without treating every Git exit 128 (including permission failures) as harmless.
        let marker = url.appendingPathComponent(".git")
        if lstat(marker.path, &metadata) != 0 {
            let error = errno
            guard error == ENOENT else {
                throw GitExecutionError.repositoryInspectionFailed(
                    path: marker.path, reason: String(cString: strerror(error))
                )
            }
            return false
        }

        let inside = try runGit(arguments: ["rev-parse", "--is-inside-work-tree"], at: url)
            .stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inside == "true" || inside == "false" else {
            throw GitExecutionError.executionFailed(
                command: gitPath, reason: "unexpected response to git rev-parse: \(inside)"
            )
        }
        guard inside == "true" else {
            return false
        }

        let topLevelData = try runGit(arguments: ["rev-parse", "--show-toplevel"], at: url).stdout
        let topLevel = String(
            decoding: topLevelData.last == 10 ? topLevelData.dropLast() : topLevelData[...],
            as: UTF8.self
        )
        let normalizedTopLevel = URL(fileURLWithPath: topLevel).standardizedFileURL.resolvingSymlinksInPath().path
        let normalizedCandidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return normalizedTopLevel == normalizedCandidate
    }

    private func runGit(arguments: [String], at directory: URL) throws -> GitCommandResult {
        let arguments = ["-C", directory.path] + arguments
        var environment = Self.gitEnvironment()
        // Bind Git to the inspected marker so corrupt metadata cannot make it
        // silently discover an enclosing repository instead.
        environment["GIT_DIR"] = directory.appendingPathComponent(".git").path
        let result = try GitProcessRunner.run(
            executable: gitPath, arguments: arguments,
            environment: environment, timeout: timeout
        )
        guard result.status == 0 else {
            throw GitLabelerError.commandFailed(
                command: ([gitPath] + arguments).joined(separator: " "),
                status: result.status,
                stderr: String(decoding: result.stderr, as: UTF8.self)
            )
        }
        return result
    }

    static func gitEnvironment(
        inheriting environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = environment
        for key in [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM",
            "GIT_PREFIX", "GIT_INTERNAL_SUPER_PREFIX", "GIT_SUPER_PREFIX",
            "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE", "GIT_SHALLOW_FILE",
            "GIT_NAMESPACE"
        ] {
            environment.removeValue(forKey: key)
        }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }

    private static func ascii(_ scalar: UnicodeScalar) -> UInt8 {
        UInt8(scalar.value)
    }
}
