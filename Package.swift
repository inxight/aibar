// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIBar",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "AIBar",
            path: "Sources/AIBar"
        ),
        .testTarget(
            name: "AIBarTests",
            dependencies: ["AIBar"],
            path: "Tests/AIBarTests"
        ),
    ]
)
