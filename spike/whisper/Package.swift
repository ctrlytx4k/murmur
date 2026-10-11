// swift-tools-version: 6.0
import PackageDescription

// Throwaway. Kept apart from the main spike package so the Whisper and Parakeet
// dependency trees never mix and each can be removed on its own.
let package = Package(
    name: "whisperbench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(name: "whisperbench", dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]),
    ],
    swiftLanguageModes: [.v5]
)
