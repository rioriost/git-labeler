import XCTest
@testable import GitLabelerCore

final class FinderTagTests: XCTestCase {
    private let fileManager = FileManager.default

    func testDecodesColoredTag() {
        XCTAssertEqual(FinderTag.decode("git:deleted\n6"), FinderTag(name: "git:deleted", color: 6))
    }

    func testDecodesPlainTag() {
        XCTAssertEqual(FinderTag.decode("important"), FinderTag(name: "important"))
    }

    func testEncodesColoredTag() {
        XCTAssertEqual(FinderTag(name: "git:modified", color: 5).encodedValue, "git:modified\n5")
    }

    func testReadsNoTagsWhenAttributeDoesNotExist() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        XCTAssertEqual(try FinderTagger().readTags(from: directory), [])
    }

    func testReplacesManagedTag() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let tagger = FinderTagger()
        let tagNames = GitLabelerConfig.TagNames()

        try tagger.apply(state: .untracked, to: directory, tagNames: tagNames)
        try tagger.apply(state: .modified, to: directory, tagNames: tagNames)

        XCTAssertEqual(
            try tagger.readTags(from: directory),
            [FinderTag(name: tagNames.modified, color: 5)]
        )
    }

    func testCleanStateRemovesManagedAttribute() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let tagger = FinderTagger()
        let tagNames = GitLabelerConfig.TagNames()

        try tagger.apply(state: .deleted, to: directory, tagNames: tagNames)
        try tagger.apply(state: .clean, to: directory, tagNames: tagNames)

        XCTAssertEqual(try tagger.readTags(from: directory), [])
    }

    func testMissingDirectoryIsIgnoredDuringApply() throws {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertNoThrow(
            try FinderTagger().apply(
                state: .untracked,
                to: directory,
                tagNames: GitLabelerConfig.TagNames()
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
