// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Parakeet speech recognition. Apache 2.0. The text-normalisation trait is off: it pulls a prebuilt binary we do not need.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: []),
    ],
    targets: [
        // Everything lives in MurmurKit so tests can reach it; the executable is only an entry point.
        .target(
            name: "MurmurKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "MurmurKitTests", dependencies: ["MurmurKit"]),
    ],
    swiftLanguageModes: [.v6]
)
