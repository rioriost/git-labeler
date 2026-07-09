import Foundation
import GitLabelerCore

@main
struct GitLabelerCLI {
    static func main() {
        do {
            try requireArm64()
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("git-labeler: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "-h", "--help", "help":
            printUsage()
        case "-V", "--version", "version":
            print(AppConstants.version)
        case "config":
            try runConfig(Array(arguments.dropFirst()))
        case "scan":
            try runScan()
        case "daemon":
            try runDaemon()
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func runConfig(_ arguments: [String]) throws {
        let store = ConfigStore()
        guard let subcommand = arguments.first else {
            printConfigUsage()
            return
        }

        switch subcommand {
        case "path":
            print(store.url.path)
        case "list":
            let config = try store.load()
            if config.roots.isEmpty {
                print("No roots configured.")
            } else {
                for root in config.roots {
                    print(root)
                }
            }
        case "add":
            guard arguments.count == 2 else { throw CLIError.invalidArguments("usage: git-labeler config add PATH") }
            let config = try store.addRoot(arguments[1])
            print("Added root. Configured roots:")
            for root in config.roots {
                print(root)
            }
        case "remove", "rm":
            guard arguments.count == 2 || arguments.count == 3 else {
                throw CLIError.invalidArguments("usage: git-labeler config remove PATH [--clear-labels]")
            }
            let clearLabels = arguments.count == 3
            if clearLabels && arguments[2] != "--clear-labels" {
                throw CLIError.invalidArguments("usage: git-labeler config remove PATH [--clear-labels]")
            }

            let configBeforeRemoval = try store.load()
            let removedRoot = clearLabels
                ? try ConfigStore.normalizedDirectoryPath(arguments[1])
                : ConfigStore.normalizedPath(arguments[1])
            let wasConfigured = configBeforeRemoval.roots.contains(removedRoot)
            let scanner = clearLabels && wasConfigured ? try RepoScanner(config: configBeforeRemoval) : nil
            let config = try store.removeRoot(arguments[1])

            if clearLabels {
                let results = scanner?.clearRoot(URL(fileURLWithPath: removedRoot, isDirectory: true)) ?? []
                let clearedCount = results.filter(\.cleared).count
                print("Cleared managed labels from \(clearedCount) repositories under \(removedRoot).")
                for result in results where result.errorDescription != nil {
                    print("error\t\(result.repositoryURL.path)\t\(result.errorDescription ?? "")")
                }
            }

            print("Removed root if present. Configured roots:")
            for root in config.roots {
                print(root)
            }
        default:
            throw CLIError.unknownCommand("config \(subcommand)")
        }
    }

    private static func runScan() throws {
        let config = try ConfigStore().load()
        let scanner = try RepoScanner(config: config)

        guard !config.roots.isEmpty else {
            print("No roots configured. Run `git-labeler config add PATH`.")
            return
        }

        for root in config.roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            for result in scanner.scanRoot(rootURL) {
                if let errorDescription = result.errorDescription {
                    print("error\t\(result.repositoryURL.path)\t\(errorDescription)")
                } else if let state = result.state {
                    print("\(state.rawValue)\t\(result.repositoryURL.path)")
                }
            }
        }
    }

    private static func runDaemon() throws {
        let config = try ConfigStore().load()
        try GitLabelerDaemon(config: config).run()
    }

    private static func requireArm64() throws {
        #if arch(arm64)
        return
        #else
        throw GitLabelerError.unsupportedArchitecture(ProcessInfo.processInfo.machineHardwareName)
        #endif
    }

    private static func printUsage() {
        print(
            """
            Usage:
              git-labeler daemon
              git-labeler scan
              git-labeler config list
              git-labeler config add PATH
              git-labeler config remove PATH [--clear-labels]
              git-labeler config path
              git-labeler --version
            """
        )
    }

    private static func printConfigUsage() {
        print(
            """
            Usage:
              git-labeler config list
              git-labeler config add PATH
              git-labeler config remove PATH [--clear-labels]
              git-labeler config path
            """
        )
    }
}

private enum CLIError: Error, LocalizedError {
    case unknownCommand(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "unknown command: \(command)"
        case .invalidArguments(let message):
            return message
        }
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
