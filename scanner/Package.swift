// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Farlock",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "Farlock", path: "Sources/Farlock"),
    ]
)
