// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Mancia",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Mancia",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Mancia"
        ),
        .testTarget(
            name: "ManciaTests",
            dependencies: ["Mancia"],
            path: "Tests/ManciaTests"
        ),
    ],
    swiftLanguageVersions: [.v6]
)
