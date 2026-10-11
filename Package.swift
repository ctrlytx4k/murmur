// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26)],
    targets: [
        // Everything lives in MurmurKit so tests can reach it; the executable is only an entry point.
        .target(
            name: "MurmurKit",
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
