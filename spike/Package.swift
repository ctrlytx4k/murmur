// swift-tools-version: 6.2
import PackageDescription

// Throwaway spike. One executable per experiment.
let package = Package(
    name: "spike",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "SpikeSupport"),
        .executableTarget(name: "hotkey", dependencies: ["SpikeSupport"]),
    ],
    swiftLanguageModes: [.v5]
)
