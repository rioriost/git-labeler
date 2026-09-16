import Darwin
import Foundation

public final class ServiceLock {
    private let descriptor: Int32

    public init(url: URL = AppConstants.applicationSupportDirectory.appendingPathComponent("daemon.lock")) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let errorNumber = errno
            close(descriptor)
            if errorNumber == EWOULDBLOCK {
                throw ServiceLockError.busy
            }
            throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
        }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }
}

private enum ServiceLockError: Error, LocalizedError {
    case busy

    var errorDescription: String? {
        "the daemon or another label-clearing operation is running; stop the LaunchAgent or foreground daemon before continuing"
    }
}
