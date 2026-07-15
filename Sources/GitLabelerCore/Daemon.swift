import Foundation

public final class GitLabelerDaemon {
    private let config: GitLabelerConfig
    private let roots: [URL]
    private let scanner: RepoScanner
    private var watcher: EventWatcher?
    private var rescanTimer: DispatchSourceTimer?

    public init(config: GitLabelerConfig) throws {
        self.config = config
        self.roots = config.roots.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }
        self.scanner = try RepoScanner(config: config)
    }

    public func run() {
        guard !roots.isEmpty else {
            Self.log("no roots configured; run `git-labeler config add PATH` and restart the service")
            dispatchMain()
        }

        Self.log("starting with \(roots.count) root(s)")
        scanAll()

        let debouncer = RepositoryDebouncer(milliseconds: config.debounceMilliseconds) { [scanner] url in
            let result = scanner.scanRepositoryCandidate(url)
            GitLabelerDaemon.log(result)
        }

        let watcher = EventWatcher(roots: roots) { url in
            debouncer.schedule(url)
        }
        watcher.start()
        self.watcher = watcher

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "st.rio.git-labeler.rescan"))
        timer.schedule(deadline: .now() + .seconds(config.rescanIntervalSeconds), repeating: .seconds(config.rescanIntervalSeconds))
        timer.setEventHandler { [weak self] in
            self?.scanAll()
        }
        timer.resume()
        self.rescanTimer = timer

        dispatchMain()
    }

    private func scanAll() {
        for root in roots {
            let results = scanner.scanRoot(root)
            for result in results where result.errorDescription != nil {
                Self.log(result)
            }

            let states = results.compactMap(\.state)
            let cleanCount = states.filter { $0 == .clean }.count
            let untrackedCount = states.filter { $0 == .untracked }.count
            let modifiedCount = states.filter { $0 == .modified }.count
            let deletedCount = states.filter { $0 == .deleted }.count
            let errorCount = results.filter { $0.errorDescription != nil }.count
            Self.log(
                "scanned \(root.path): \(states.count) repositories "
                    + "(clean \(cleanCount), untracked \(untrackedCount), "
                    + "modified \(modifiedCount), deleted \(deletedCount)), errors \(errorCount)"
            )
        }
    }

    private static func log(_ result: ScanResult) {
        if let errorDescription = result.errorDescription {
            log("error \(result.repositoryURL.path): \(errorDescription)")
        } else if let state = result.state {
            log("\(state.rawValue) \(result.repositoryURL.path)")
        }
    }

    public static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(timestamp)] \(message)\n".utf8))
    }
}
