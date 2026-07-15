import Foundation

public enum AppConstants {
    public static let version = "0.1.3"
    public static let bundleIdentifier = "st.rio.git-labeler"
    public static let plistFileName = "st.rio.git-labeler.plist"
    public static let defaultDebounceMilliseconds = 750
    public static let defaultRescanIntervalSeconds = 300

    public static let untrackedTagName = "git:untracked"
    public static let modifiedTagName = "git:modified"
    public static let deletedTagName = "git:deleted"

    public static let managedTagNames: Set<String> = [
        untrackedTagName,
        modifiedTagName,
        deletedTagName
    ]

    public static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static var defaultConfigURL: URL {
        applicationSupportDirectory.appendingPathComponent("config.json")
    }

    public static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }
}
