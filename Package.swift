// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EasyPort",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "EasyPort", path: "Sources/EasyPort")
    ]
)
