import Darwin
import Foundation

public struct FinderTag: Equatable {
    public var name: String
    public var color: Int?

    public init(name: String, color: Int? = nil) {
        self.name = name
        self.color = color
    }

    public var encodedValue: String {
        if let color {
            return "\(name)\n\(color)"
        }
        return name
    }

    public static func decode(_ value: String) -> FinderTag {
        guard let separator = value.lastIndex(of: "\n") else {
            return FinderTag(name: value)
        }

        let name = String(value[..<separator])
        let colorText = value[value.index(after: separator)...]
        return FinderTag(name: name, color: Int(colorText))
    }
}

public protocol FinderTagApplying {
    func apply(state: RepositoryState, to url: URL, tagNames: GitLabelerConfig.TagNames) throws
    func clearManagedTags(from url: URL, tagNames: GitLabelerConfig.TagNames) throws
}

public final class FinderTagger: FinderTagApplying {
    private let attributeName = "com.apple.metadata:_kMDItemUserTags"

    public init() {}

    public func apply(state: RepositoryState, to url: URL, tagNames: GitLabelerConfig.TagNames) throws {
        var tags = try readTags(from: url)
        tags.removeAll { managedTagNames(for: tagNames).contains($0.name) }

        switch state {
        case .clean:
            break
        case .untracked:
            tags.append(FinderTag(name: tagNames.untracked, color: 2))
        case .modified:
            tags.append(FinderTag(name: tagNames.modified, color: 5))
        case .deleted:
            tags.append(FinderTag(name: tagNames.deleted, color: 6))
        }

        try writeTags(tags, to: url)
    }

    public func clearManagedTags(from url: URL, tagNames: GitLabelerConfig.TagNames) throws {
        var tags = try readTags(from: url)
        tags.removeAll { managedTagNames(for: tagNames).contains($0.name) }
        try writeTags(tags, to: url)
    }

    public func readTags(from url: URL) throws -> [FinderTag] {
        guard let data = try readTagData(from: url) else {
            return []
        }

        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let values = propertyList as? [String] else {
            return []
        }
        return values.map(FinderTag.decode)
    }

    private func writeTags(_ tags: [FinderTag], to url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw POSIXError(.EINVAL)
            }

            guard !tags.isEmpty else {
                if removexattr(path, attributeName, 0) != 0,
                   !isMissingAttributeOrFile(errno) {
                    throw posixError(errno)
                }
                return
            }

            let values = tags.map(\.encodedValue)
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.withUnsafeBytes { buffer in
                if setxattr(path, attributeName, buffer.baseAddress, data.count, 0, 0) != 0,
                   errno != ENOENT {
                    throw posixError(errno)
                }
            }
        }
    }

    private func readTagData(from url: URL) throws -> Data? {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw POSIXError(.EINVAL)
            }

            // The attribute can change between the size query and the read.
            for _ in 0..<3 {
                let size = getxattr(path, attributeName, nil, 0, 0, 0)
                if size < 0 {
                    if isMissingAttributeOrFile(errno) {
                        return nil
                    }
                    throw posixError(errno)
                }
                guard size > 0 else {
                    return nil
                }

                var data = Data(count: size)
                let readSize = data.withUnsafeMutableBytes { buffer in
                    getxattr(path, attributeName, buffer.baseAddress, size, 0, 0)
                }
                if readSize >= 0 {
                    data.count = readSize
                    return data
                }
                if errno == ERANGE {
                    continue
                }
                if isMissingAttributeOrFile(errno) {
                    return nil
                }
                throw posixError(errno)
            }

            throw POSIXError(.EAGAIN)
        }
    }

    private func isMissingAttributeOrFile(_ errorNumber: Int32) -> Bool {
        errorNumber == ENOATTR || errorNumber == ENOENT
    }

    private func posixError(_ errorNumber: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
    }

    private func managedTagNames(for tagNames: GitLabelerConfig.TagNames) -> Set<String> {
        AppConstants.managedTagNames.union([
            tagNames.untracked,
            tagNames.modified,
            tagNames.deleted
        ])
    }
}
