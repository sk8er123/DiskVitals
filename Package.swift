// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskVitals",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DiskVitals",
            path: "Sources/DiskVitals"
        )
    ]
)
