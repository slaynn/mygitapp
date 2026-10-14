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
            dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")],
            path: "Sources/MyGitApp"
        ),
        .testTarget(
            name: "MyGitAppTests",
            dependencies: ["MyGitApp"],
            path: "Tests/MyGitAppTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
