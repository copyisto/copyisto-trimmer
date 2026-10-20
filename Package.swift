// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CopyistoTrimmer",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "CopyistoTrimmer"),
        .testTarget(name: "CopyistoTrimmerTests", dependencies: ["CopyistoTrimmer"]),
    ]
)
