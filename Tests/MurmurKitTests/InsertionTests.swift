import AppKit
import Foundation
import Testing
@testable import MurmurKit

/// The paste path with the key press stubbed out, on a private pasteboard: what is on the clipboard
/// when the target app reads it, and what is there afterwards.
@MainActor
@Suite struct PasteInsertionTests {
    private func pasteboard(holding text: String?) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("murmur-tests-\(UUID().uuidString)"))
        pb.clearContents()
        if let text { pb.setString(text, forType: .string) }
        return pb
    }

    private func settings() -> SettingsStore {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        settings.addsTrailingSpace = false
        return settings
    }

    @Test func theTextStaysOnTheClipboardUntilTheAppHasHadTimeToReadIt() async throws {
        let pb = pasteboard(holding: "what the user had copied")
        var pastes = 0
        let insertion = PasteInsertion(settings: settings(), pasteboard: pb, restoreDelay: .milliseconds(150), isTrusted: { true }) { pastes += 1 }
        let receipt = try await insertion.insert("hello")
        #expect(receipt.text == "hello")
        #expect(pastes == 1)
        // A slow app pasting now still gets the dictated text, not the old clipboard.
        #expect(pb.string(forType: .string) == "hello")
        await insertion.restoreTask?.value
        #expect(pb.string(forType: .string) == "what the user had copied")
        #expect(insertion.restoreTask == nil)
    }

    @Test func aSecondTakeBeforeTheRestoreStillReturnsTheUsersOwnClipboard() async throws {
        let pb = pasteboard(holding: "what the user had copied")
        let insertion = PasteInsertion(settings: settings(), pasteboard: pb, restoreDelay: .milliseconds(150), isTrusted: { true }) {}
        _ = try await insertion.insert("first take")
        _ = try await insertion.insert("second take")
        #expect(pb.string(forType: .string) == "second take")
        await insertion.restoreTask?.value
        #expect(pb.string(forType: .string) == "what the user had copied")
    }

    @Test func somethingCopiedInTheMeantimeIsLeftAlone() async throws {
        let pb = pasteboard(holding: "old")
        let insertion = PasteInsertion(settings: settings(), pasteboard: pb, restoreDelay: .milliseconds(150), isTrusted: { true }) {}
        _ = try await insertion.insert("hello")
        pb.clearContents()
        pb.setString("copied by the user just now", forType: .string)
        await insertion.restoreTask?.value
        #expect(pb.string(forType: .string) == "copied by the user just now")
    }

    @Test func quittingRestoresAtOnce() async throws {
        let pb = pasteboard(holding: "old")
        let insertion = PasteInsertion(settings: settings(), pasteboard: pb, restoreDelay: .seconds(60), isTrusted: { true }) {}
        _ = try await insertion.insert("hello")
        insertion.flushRestore()
        #expect(pb.string(forType: .string) == "old")
    }

    @Test func anEmptyClipboardGoesBackToEmpty() async throws {
        let pb = pasteboard(holding: nil)
        let insertion = PasteInsertion(settings: settings(), pasteboard: pb, restoreDelay: .milliseconds(50), isTrusted: { true }) {}
        _ = try await insertion.insert("hello")
        await insertion.restoreTask?.value
        #expect(pb.string(forType: .string) == nil)
    }

    @Test func restoreCanBeSwitchedOffAndTheSpaceIsOptional() async throws {
        let pb = pasteboard(holding: "old")
        let settings = settings()
        settings.restoresClipboard = false
        settings.addsTrailingSpace = true
        let insertion = PasteInsertion(settings: settings, pasteboard: pb, restoreDelay: .milliseconds(50), isTrusted: { true }) {}
        let receipt = try await insertion.insert("hello")
        #expect(receipt.text == "hello ")
        #expect(insertion.restoreTask == nil)
        #expect(pb.string(forType: .string) == "hello ")
    }
}
