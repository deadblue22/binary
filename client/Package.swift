// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Binary",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Binary",
            path: "Sources/Binary"
        ),
    ]
)
