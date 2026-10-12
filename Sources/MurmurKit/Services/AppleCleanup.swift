import Foundation
import FoundationModels

/// Cleanup with the language model built into macOS (Apple Intelligence). It runs on this Mac,
/// there is nothing to download and nothing leaves the machine.
public final class AppleCleanup: TextCleanupService, LocalTextModel {
    public init() {}

    public var availability: CleanupAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: .available(model: "Apple Intelligence")
        case .unavailable(.deviceNotEligible): .unavailable("This Mac doesn’t support Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled): .unavailable("Apple Intelligence is turned off in System Settings")
        case .unavailable(.modelNotReady): .unavailable("Apple Intelligence is still getting ready")
        case .unavailable: .unavailable("Apple Intelligence isn’t available")
        }
    }

    public func clean(_ text: String, instructions: String) async throws -> String {
        guard case .available = availability else { throw CleanupFailure.unavailable }
        // The model's context is small. A very long take goes in as spoken rather than being cut short.
        guard text.count <= 6000 else { throw CleanupFailure.tooLong }

        // A fresh session per take: one take must never colour the next.
        let session = LanguageModelSession(instructions: CleanupPrompt.system(style: instructions))
        let work = Task { try await session.respond(to: CleanupPrompt.user(text)).content }
        let limit = Task {
            try await Task.sleep(for: .seconds(8 + Double(text.count) / 150))
            work.cancel()
        }
        defer { limit.cancel() }
        let cleaned = CleanupCheck.tidy(try await work.value)
        guard CleanupCheck.accepts(raw: text, cleaned: cleaned) else { throw CleanupFailure.rejected }
        return cleaned
    }

    public func generate(system: String, user: String) async throws -> String {
        guard case .available = availability else { throw CleanupFailure.unavailable }
        let session = LanguageModelSession(instructions: system)
        let work = Task { try await session.respond(to: user).content }
        let limit = Task {
            try await Task.sleep(for: .seconds(60))
            work.cancel()
        }
        defer { limit.cancel() }
        return try await work.value
    }
}
