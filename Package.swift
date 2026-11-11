// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hogwatch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "hogwatch",
            path: "Sources/hogwatch"
        )
    ]
)
