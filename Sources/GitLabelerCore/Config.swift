import Foundation

public struct GitLabelerConfig: Codable, Equatable {
    public var version: Int
    public var roots: [String]
    public var debounceMilliseconds: Int
    public var rescanIntervalSeconds: Int
    public var gitPath: String?
    public var tags: TagNames

    public struct TagNames: Codable, Equatable {
        public var untracked: String
        public var modified: String
        public var deleted: String

        public init(
            untracked: String = AppConstants.untrackedTagName,
            modified: String = AppConstants.modifiedTagName,
            deleted: String = AppConstants.deletedTagName
        ) {
            self.untracked = untracked
            self.modified = modified
            self.deleted = deleted
        }
    }

    public init(
        version: Int = 1,
        roots: [String] = [],
        debounceMilliseconds: Int = AppConstants.defaultDebounceMilliseconds,
        rescanIntervalSeconds: Int = AppConstants.defaultRescanIntervalSeconds,
        gitPath: String? = nil,
        tags: TagNames = TagNames()
    ) {
        self.version = version
        self.roots = roots
        self.debounceMilliseconds = debounceMilliseconds
        self.rescanIntervalSeconds = rescanIntervalSeconds
        self.gitPath = gitPath
        self.tags = tags
    }

    public func validate(fileManager: FileManager = .default) throws {
        guard version == 1 else {
            throw GitLabelerError.invalidConfiguration("version", "only version 1 is supported")
        }
        guard (0...60_000).contains(debounceMilliseconds) else {
            throw GitLabelerError.invalidConfiguration("debounceMilliseconds", "must be between 0 and 60000")
        }
        guard (1...86_400).contains(rescanIntervalSeconds) else {
            throw GitLabelerError.invalidConfiguration("rescanIntervalSeconds", "must be between 1 and 86400")
        }
        for root in roots {
            guard root.hasPrefix("/"), !root.contains("\0") else {
                throw GitLabelerError.invalidConfiguration("roots", "paths must be absolute and contain no NUL characters")
            }
        }
        if let gitPath {
            var isDirectory: ObjCBool = false
            guard gitPath.hasPrefix("/"),
                  !gitPath.contains("\0"),
                  fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: gitPath) else {
                throw GitLabelerError.invalidConfiguration("gitPath", "must be null or an absolute path to an executable file")
            }
        }
        let names = [tags.untracked, tags.modified, tags.deleted]
        guard names.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else {
            throw GitLabelerError.invalidConfiguration("tags", "names must be nonempty and contain no control characters")
        }
        guard Set(names).count == names.count else {
            throw GitLabelerError.invalidConfiguration("tags", "names must be distinct")
        }
    }
}

public final class ConfigStore {
    public let url: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL = AppConstants.defaultConfigURL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
    }

    public func load() throws -> GitLabelerConfig {
        guard fileManager.fileExists(atPath: url.path) else {
            return GitLabelerConfig()
        }

        let data = try Data(contentsOf: url)
        let config = try decoder.decode(GitLabelerConfig.self, from: data)
        try config.validate(fileManager: fileManager)
        return config
    }

    public func save(_ config: GitLabelerConfig) throws {
        try config.validate(fileManager: fileManager)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        try data.write(to: url, options: [.atomic])
    }

    @discardableResult
    public func addRoot(_ input: String) throws -> GitLabelerConfig {
        var config = try load()
        let normalized = try Self.normalizedDirectoryPath(input, fileManager: fileManager)

        if !config.roots.contains(normalized) {
            config.roots.append(normalized)
            config.roots.sort()
            try save(config)
        }

        return config
    }

    @discardableResult
    public func removeRoot(_ input: String) throws -> GitLabelerConfig {
        var config = try load()
        let normalized = Self.normalizedPath(input)
        config.roots.removeAll { Self.normalizedPath($0) == normalized }
        try save(config)
        return config
    }

    public static func normalizedDirectoryPath(_ input: String, fileManager: FileManager = .default) throws -> String {
        let url = URL(fileURLWithPath: expandedPath(input)).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitLabelerError.invalidDirectory(input)
        }
        return url.path
    }

    public static func normalizedPath(_ input: String) -> String {
        URL(fileURLWithPath: expandedPath(input)).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func expandedPath(_ input: String) -> String {
        let expanded = (input as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
            .path
    }
}

public enum GitLabelerError: Error, LocalizedError, Equatable {
    case invalidDirectory(String)
    case invalidConfiguration(String, String)
    case unsupportedArchitecture(String)
    case gitNotFound
    case commandFailed(command: String, status: Int32, stderr: String)
    case notRepository(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory(let path):
            return "not a directory: \(path)"
        case .invalidConfiguration(let field, let reason):
            return "invalid configuration '\(field)': \(reason)"
        case .unsupportedArchitecture(let architecture):
            return "git-labeler supports arm64 only; current architecture is \(architecture)"
        case .gitNotFound:
            return "git executable was not found"
        case .commandFailed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "\(command) failed with exit status \(status)"
            }
            return "\(command) failed with exit status \(status): \(detail)"
        case .notRepository(let url):
            return "not a git repository root: \(url.path)"
        }
    }
}
