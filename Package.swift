// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyGitApp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "MyGitApp",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                "GitGardenerCore",
            ],
            path: "Sources/MyGitApp"
        ),
        // Local branches and worktrees: analysis, safety verdicts, prune and prune log (no UI).
        .target(
            name: "GitGardenerCore",
            path: "Sources/GitGardenerCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MyGitAppTests",
            dependencies: ["MyGitApp"],
            path: "Tests/MyGitAppTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "GitGardenerCoreTests",
            dependencies: ["GitGardenerCore"],
            path: "Tests/GitGardenerCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
