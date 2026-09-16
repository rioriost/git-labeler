import Foundation
import XCTest
@testable import GitLabelerCore

final class ServiceLockTests: XCTestCase {
    func testExclusiveLockIsReleasedWithoutRemovingLockFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("daemon.lock")
        do {
            let lock = try ServiceLock(url: url)
            try withExtendedLifetime(lock) {
                XCTAssertThrowsError(try ServiceLock(url: url)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("stop the LaunchAgent"))
                }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let nextLock = try ServiceLock(url: url)
        withExtendedLifetime(nextLock) {}
    }
}
