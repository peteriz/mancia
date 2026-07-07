// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AIEdit",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AIEdit",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/AIEdit"
        ),
        .testTarget(
            name: "AIEditTests",
            dependencies: ["AIEdit"],
            path: "Tests/AIEditTests"
        ),
    ]
)
