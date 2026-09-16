import CoreServices
import Foundation

public final class EventWatcher {
    public typealias Handler = (URL) -> Void

    private let roots: [URL]
    private let handler: Handler
    private let queue = DispatchQueue(label: "st.rio.git-labeler.fsevents")
    private var streams: [FSEventStreamRef] = []

    public init(roots: [URL], handler: @escaping Handler) {
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        stop()
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        for root in roots {
            var streamContext = FSEventStreamContext(
                version: 0,
                info: context,
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let callback: FSEventStreamCallback = { _, info, count, pathsPointer, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<EventWatcher>.fromOpaque(info).takeUnretainedValue()
                let eventPaths = unsafeBitCast(pathsPointer, to: CFArray.self)
                guard let paths = eventPaths as? [String] else { return }

                for path in paths.prefix(count) {
                    watcher.handleEventPath(path)
                }
            }

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &streamContext,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
            ) else {
                stop()
                throw EventWatcherError.cannotWatch(root)
            }

            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                stop()
                throw EventWatcherError.cannotWatch(root)
            }
            streams.append(stream)
        }
    }

    public func stop() {
        for stream in streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streams.removeAll()
    }

    private func handleEventPath(_ path: String) {
        let eventURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()

        for repositoryURL in repositoryCandidates(for: eventURL) {
            handler(repositoryURL)
        }
    }

    public func repositoryCandidate(for eventURL: URL) -> URL? {
        repositoryCandidates(for: eventURL).first
    }

    public func repositoryCandidates(for eventURL: URL) -> [URL] {
        let eventPath = eventURL.path
        var candidates: [URL] = []
        var seen: Set<String> = []

        for root in roots {
            let rootPath = root.path
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard eventPath.hasPrefix(prefix) else {
                continue
            }

            let relative = String(eventPath.dropFirst(prefix.count))
            let components = relative.split(separator: "/")
            guard let firstComponent = components.first else {
                continue
            }
            if components.count >= 3,
               components[1] == ".git",
               components[2] == "fsmonitor--daemon" {
                continue
            }

            let candidate = root.appendingPathComponent(String(firstComponent), isDirectory: true)
            if seen.insert(candidate.path).inserted {
                candidates.append(candidate)
            }
        }

        return candidates
    }
}

private enum EventWatcherError: Error, LocalizedError {
    case cannotWatch(URL)

    var errorDescription: String? {
        switch self {
        case .cannotWatch(let root):
            return "cannot start filesystem monitoring for \(root.path)"
        }
    }
}

public final class RepositoryDebouncer {
    private let delay: DispatchTimeInterval
    private let queue: DispatchQueue
    private var pending: [String: DispatchWorkItem] = [:]
    private let handler: (URL) -> Void

    public init(
        milliseconds: Int,
        queue: DispatchQueue = DispatchQueue(label: "st.rio.git-labeler.debounce"),
        handler: @escaping (URL) -> Void
    ) {
        self.delay = .milliseconds(max(milliseconds, 0))
        self.queue = queue
        self.handler = handler
    }

    public func schedule(_ url: URL) {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path

        queue.async { [self] in
            self.pending[key]?.cancel()

            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending[key] = nil
                self.handler(URL(fileURLWithPath: key, isDirectory: true))
            }

            self.pending[key] = item
            self.queue.asyncAfter(deadline: .now() + self.delay, execute: item)
        }
    }
}
