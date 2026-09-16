import Darwin
import Foundation

struct GitCommandResult {
    var stdout: Data
    var stderr: Data
    var status: Int32

    var stdoutText: String {
        String(decoding: stdout, as: UTF8.self)
    }
}

enum GitProcessRunner {
    static func run(
        executable: String, arguments: [String],
        environment: [String: String], timeout: TimeInterval
    ) throws -> GitCommandResult {
        let command = ([executable] + arguments).joined(separator: " ")
        func failure(_ reason: String, code: Int32 = errno) -> GitExecutionError {
            .executionFailed(command: command, reason: "\(reason): \(String(cString: strerror(code)))")
        }
        func check(_ code: Int32, _ operation: String) throws {
            guard code == 0 else { throw failure(operation, code: code) }
        }

        guard timeout.isFinite, timeout > 0 else {
            throw GitExecutionError.invalidTimeout(timeout)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let stdout = try makePipe()
        defer { close(stdout.read); close(stdout.write) }
        let stderr = try makePipe()
        defer { close(stderr.read); close(stderr.write) }

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), "preparing file descriptors")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            "redirecting standard input"
        )
        for (pipe, destination) in [(stdout, STDOUT_FILENO), (stderr, STDERR_FILENO)] {
            try check(posix_spawn_file_actions_adddup2(&actions, pipe.write, destination), "redirecting output")
            try check(posix_spawn_file_actions_addclose(&actions, pipe.read), "closing child read descriptor")
            try check(posix_spawn_file_actions_addclose(&actions, pipe.write), "closing child write descriptor")
        }

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), "preparing process attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setpgroup(&attributes, 0), "creating process group")
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask), "resetting signal mask")
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGPIPE, SIGHUP, SIGQUIT] {
            sigaddset(&defaults, signal)
        }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), "resetting signal handlers")
        try check(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
            ),
            "setting process attributes"
        )

        var argv = ([executable] + arguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { envp.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else {
            throw failure("allocating command arguments", code: ENOMEM)
        }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        let launchStatus = argv.withUnsafeMutableBufferPointer { argv in
            envp.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try check(launchStatus, "launching Git")
        var reaped = false
        defer {
            if !reaped { terminateAndReap(pid) }
        }
        // Only the child's writers may keep these pipes open. Invalidate our copies
        // after closing so cleanup cannot close an unrelated, reused descriptor.
        close(stdout.write)
        stdout.write = -1
        close(stderr.write)
        stderr.write = -1

        var stdoutData = Data()
        var stderrData = Data()
        var stdoutOpen = true
        var stderrOpen = true
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            // Do not reap while descendants hold a pipe: retaining the child's PID
            // prevents process-group ID reuse before timeout cleanup.
            if !stdoutOpen && !stderrOpen {
                var information = siginfo_t()
                let waited = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
                if waited == 0 && information.si_pid == pid {
                    // A helper that closed its output may still be alive. Finish
                    // the owned group before reaping, while its ID cannot be reused.
                    kill(-pid, SIGKILL)
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) == -1 {
                        if errno == EINTR { continue }
                        if errno == ECHILD { reaped = true }
                        throw failure("reaping Git")
                    }
                    reaped = true
                    let signal = status & 0x7f
                    return GitCommandResult(
                        stdout: stdoutData, stderr: stderrData,
                        status: signal == 0 ? (status >> 8) & 0xff : 128 + signal
                    )
                }
                if waited == -1 && errno != EINTR {
                    if errno == ECHILD { reaped = true }
                    throw failure("waiting for Git")
                }
            }

            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw GitExecutionError.timedOut(command: command, timeout: timeout)
            }
            var descriptors = [
                pollfd(fd: stdoutOpen ? stdout.read : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stderrOpen ? stderr.read : -1, events: Int16(POLLIN), revents: 0)
            ]
            let ready = poll(&descriptors, 2, Int32(min(20, max(1, remaining * 1_000))))
            if ready == -1 {
                if errno == EINTR { continue }
                throw failure("polling Git output")
            }
            for index in descriptors.indices where descriptors[index].revents != 0 {
                let count = read(descriptors[index].fd, &buffer, buffer.count)
                if count > 0 {
                    if index == 0 {
                        stdoutData.append(contentsOf: buffer.prefix(count))
                    } else {
                        stderrData.append(contentsOf: buffer.prefix(count))
                    }
                } else if count == 0 {
                    if index == 0 { stdoutOpen = false } else { stderrOpen = false }
                } else if errno != EAGAIN && errno != EINTR {
                    throw failure("reading Git output")
                }
            }
        }
    }

    private final class OutputPipe {
        let read: Int32
        var write: Int32

        init(read: Int32, write: Int32) {
            self.read = read
            self.write = write
        }
    }

    private static func makePipe() throws -> OutputPipe {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw GitExecutionError.executionFailed(
                command: "Git", reason: "creating output pipe: \(String(cString: strerror(errno)))"
            )
        }
        for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
            let replacement = fcntl(descriptors[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard replacement != -1 else {
                let error = errno
                descriptors.forEach { close($0) }
                throw GitExecutionError.executionFailed(
                    command: "Git", reason: "configuring output pipe: \(String(cString: strerror(error)))"
                )
            }
            close(descriptors[index])
            descriptors[index] = replacement
        }
        for fd in descriptors {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else {
                let error = errno
                descriptors.forEach { close($0) }
                throw GitExecutionError.executionFailed(
                    command: "Git", reason: "configuring output pipe: \(String(cString: strerror(error)))"
                )
            }
        }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) != -1 else {
            let error = errno
            descriptors.forEach { close($0) }
            throw GitExecutionError.executionFailed(
                command: "Git", reason: "configuring output pipe: \(String(cString: strerror(error)))"
            )
        }
        return OutputPipe(read: descriptors[0], write: descriptors[1])
    }

    private static func terminateAndReap(_ pid: pid_t) {
        // The group is created atomically by posix_spawn, so Git helpers receive
        // termination too. SIGKILL bounds cleanup even when SIGTERM is ignored.
        kill(-pid, SIGTERM)
        Thread.sleep(forTimeInterval: 0.1)
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
}
