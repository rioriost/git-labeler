// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "git-labeler",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "git-labeler", targets: ["git-labeler"]),
        .library(name: "GitLabelerCore", targets: ["GitLabelerCore"])
    ],
    targets: [
        .target(name: "GitLabelerCore"),
        .executableTarget(
            name: "git-labeler",
            dependencies: ["GitLabelerCore"]
        ),
        .testTarget(
            name: "GitLabelerCoreTests",
            dependencies: ["GitLabelerCore"]
        )
    ]
)
