import Foundation

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

    public init(gitPath: String? = nil) throws {
        if let gitPath, !gitPath.isEmpty {
            self.gitPath = gitPath
        } else if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git") {
            self.gitPath = "/opt/homebrew/bin/git"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            self.gitPath = "/usr/bin/git"
        } else {
            throw GitLabelerError.gitNotFound
        }
    }

    public func state(forRepositoryRoot repositoryURL: URL) throws -> RepositoryState? {
        guard try isRepositoryRoot(repositoryURL) else {
            return nil
        }

        let data = try runGit(arguments: [
            "-C", repositoryURL.path,
            "status",
            "--porcelain=v1",
            "-z"
        ]).stdout

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

    private func isRepositoryRoot(_ url: URL) throws -> Bool {
        let inside: String
        do {
            inside = try runGit(arguments: ["-C", url.path, "rev-parse", "--is-inside-work-tree"])
                .stdoutText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return false
        }
        guard inside == "true" else {
            return false
        }

        let topLevel = try runGit(arguments: ["-C", url.path, "rev-parse", "--show-toplevel"])
            .stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTopLevel = URL(fileURLWithPath: topLevel).standardizedFileURL.resolvingSymlinksInPath().path
        let normalizedCandidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return normalizedTopLevel == normalizedCandidate
    }

    private func runGit(arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.environment = Self.gitEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GitLabelerError.commandFailed(
                command: ([gitPath] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }

        return CommandResult(stdout: stdoutData)
    }

    static func gitEnvironment(
        inheriting environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }

    private static func ascii(_ scalar: UnicodeScalar) -> UInt8 {
        UInt8(scalar.value)
    }
}

private struct CommandResult {
    var stdout: Data

    var stdoutText: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }
}
