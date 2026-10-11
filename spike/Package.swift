// swift-tools-version: 6.2
import PackageDescription

// Throwaway spike. Three experiments, one executable each.
let package = Package(
    name: "spike",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: []),
    ],
    targets: [
        .target(name: "SpikeSupport"),
        .executableTarget(name: "hotkey", dependencies: ["SpikeSupport"]),
        .executableTarget(name: "insert", dependencies: ["SpikeSupport"]),
        .executableTarget(
            name: "transcribe",
            dependencies: ["SpikeSupport", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
