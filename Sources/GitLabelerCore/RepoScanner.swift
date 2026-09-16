import Darwin
import Foundation

public struct ScanResult: Equatable {
    public var repositoryURL: URL
    public var state: RepositoryState?
    public var errorDescription: String?

    public init(repositoryURL: URL, state: RepositoryState?, errorDescription: String? = nil) {
        self.repositoryURL = repositoryURL
        self.state = state
        self.errorDescription = errorDescription
    }
}

public struct ClearResult: Equatable {
    public var repositoryURL: URL
    public var cleared: Bool
    public var errorDescription: String?

    public init(repositoryURL: URL, cleared: Bool, errorDescription: String? = nil) {
        self.repositoryURL = repositoryURL
        self.cleared = cleared
        self.errorDescription = errorDescription
    }
}

public final class RepoScanner {
    private let gitStatusReader: GitStatusReader
    private let tagger: FinderTagApplying
    private let fileManager: FileManager
    private let tagNames: GitLabelerConfig.TagNames

    public init(
        config: GitLabelerConfig,
        tagger: FinderTagApplying = FinderTagger(),
        fileManager: FileManager = .default
    ) throws {
        try config.validate(fileManager: fileManager)
        self.gitStatusReader = try GitStatusReader(gitPath: config.gitPath)
        self.tagger = tagger
        self.fileManager = fileManager
        self.tagNames = config.tags
    }

    public func scanRoot(_ root: URL) -> [ScanResult] {
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsPackageDescendants
        ]

        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else {
            return [ScanResult(repositoryURL: root, state: nil, errorDescription: "cannot read root")]
        }

        return children
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.path < $1.path }
            .map { scanRepositoryCandidate($0) }
    }

    public func scanRepositoryCandidate(_ repositoryURL: URL) -> ScanResult {
        do {
            guard try isDirectoryCandidate(repositoryURL) else {
                return ScanResult(repositoryURL: repositoryURL, state: nil)
            }
            guard let state = try gitStatusReader.state(forRepositoryRoot: repositoryURL) else {
                return ScanResult(repositoryURL: repositoryURL, state: nil)
            }
            try tagger.apply(state: state, to: repositoryURL, tagNames: tagNames)
            return ScanResult(repositoryURL: repositoryURL, state: state)
        } catch {
            return ScanResult(repositoryURL: repositoryURL, state: nil, errorDescription: error.localizedDescription)
        }
    }

    public func clearRoot(_ root: URL) -> [ClearResult] {
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsPackageDescendants
        ]

        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else {
            return [ClearResult(repositoryURL: root, cleared: false, errorDescription: "cannot read root")]
        }

        return children
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.path < $1.path }
            .map { clearRepositoryCandidate($0) }
    }

    public func clearRepositoryCandidate(_ repositoryURL: URL) -> ClearResult {
        do {
            guard try isDirectoryCandidate(repositoryURL) else {
                return ClearResult(repositoryURL: repositoryURL, cleared: false)
            }
            guard try gitStatusReader.isRepositoryRoot(repositoryURL) else {
                return ClearResult(repositoryURL: repositoryURL, cleared: false)
            }
            try tagger.clearManagedTags(from: repositoryURL, tagNames: tagNames)
            return ClearResult(repositoryURL: repositoryURL, cleared: true)
        } catch {
            return ClearResult(repositoryURL: repositoryURL, cleared: false, errorDescription: error.localizedDescription)
        }
    }

    private func isDirectoryCandidate(_ url: URL) throws -> Bool {
        var metadata = stat()
        if stat(url.path, &metadata) == 0 {
            return metadata.st_mode & S_IFMT == S_IFDIR
        }
        let errorNumber = errno
        if errorNumber == ENOENT || errorNumber == ENOTDIR {
            return false
        }
        throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
    }
}
