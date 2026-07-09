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

    public func start() {
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
                let paths = unsafeBitCast(pathsPointer, to: CFArray.self) as! [String]

                for index in 0..<count {
                    watcher.handleEventPath(paths[index])
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
                continue
            }

            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
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

        guard let repositoryURL = repositoryCandidate(for: eventURL) else {
            return
        }

        handler(repositoryURL)
    }

    public func repositoryCandidate(for eventURL: URL) -> URL? {
        let eventPath = eventURL.path

        for root in roots {
            let rootPath = root.path
            guard eventPath == rootPath || eventPath.hasPrefix(rootPath + "/") else {
                continue
            }

            let relative = String(eventPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let firstComponent = relative.split(separator: "/", maxSplits: 1).first else {
                return nil
            }

            return root.appendingPathComponent(String(firstComponent), isDirectory: true)
        }

        return nil
    }
}

public final class RepositoryDebouncer {
    private let delay: DispatchTimeInterval
    private let queue = DispatchQueue(label: "st.rio.git-labeler.debounce")
    private var pending: [String: DispatchWorkItem] = [:]
    private let handler: (URL) -> Void

    public init(milliseconds: Int, handler: @escaping (URL) -> Void) {
        self.delay = .milliseconds(max(milliseconds, 0))
        self.handler = handler
    }

    public func schedule(_ url: URL) {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path

        queue.async {
            self.pending[key]?.cancel()

            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.pending[key] = nil
                }
                self.handler(URL(fileURLWithPath: key, isDirectory: true))
            }

            self.pending[key] = item
            self.queue.asyncAfter(deadline: .now() + self.delay, execute: item)
        }
    }
}
