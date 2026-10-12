import Foundation
import Testing
@testable import MurmurKit

@MainActor
private final class SummaryFakeModel: LocalTextModel {
    var availability = CleanupAvailability.available(model: "fake")
    var prompts: [(system: String, user: String)] = []
    var fails = false
    var onCall: () -> Void = {}
    struct Broken: Error {}

    func generate(system: String, user: String) async throws -> String {
        prompts.append((system, user))
        onCall()
        if fails { throw Broken() }
        return "Key points\n- point \(prompts.count)\n\nAction items\n- None mentioned"
    }
}

/// Answers every chat request with a fixed summary, and remembers what was sent.
private final class SummaryFakeTransport: ProviderTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    /// Requests whose body is longer than this are refused, like a model whose context is too small.
    var limit = Int.max
    var sent: [String] { lock.withLock { bodies } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        lock.withLock { bodies.append(body) }
        let tooLong = body.count > limit
        let reply = tooLong ? #"{"error":{"message":"maximum context length exceeded"}}"# : #"{"choices":[{"message":{"content":"Key points\n- from the cloud\n\nAction items\n- None mentioned"},"finish_reason":"stop"}]}"#
        return (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: tooLong ? 400 : 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
@Suite struct MeetingSummaryTests {
    private struct Rig {
        let summarizer: MeetingSummarizer
        let store: MeetingStore
        let providers: ProviderStore
        let settings: SettingsStore
        let network: NetworkLog
        let model: SummaryFakeModel
        let transport: SummaryFakeTransport
        let meeting: UUID
        let raw: [MeetingLine]
    }

    private let cloud = ProviderConfig(id: "cloud", kind: .openAI, name: "OpenAI", model: "gpt-test")
    private let ollama = ProviderConfig(id: "ollama", kind: .localServer, name: "Ollama", model: "llama3.2:3b")

    private func rig(lines count: Int = 3) -> Rig {
        let defaults = UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let providers = ProviderStore(defaults: defaults, keys: MemoryKeyStore())
        let network = NetworkLog(defaults: defaults)
        let transport = SummaryFakeTransport()
        let router = CleanupRouter(local: nil, providers: providers, settings: settings, transport: transport, network: network)
        let store = MeetingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("murmur-summary-tests-\(UUID().uuidString)"))
        let model = SummaryFakeModel()
        var meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 5_000), duration: 600, includesCallAudio: true)
        let raw = (0..<count).map { MeetingLine(start: Double($0) * 10, speaker: $0 % 2 == 0 ? .you : .others, text: "um so line \($0) uh exactly as it was heard, with every filler") }
        meeting.setTranscript(raw, engine: "fake")
        store.add(meeting)
        providers.save(cloud, key: "test-key")
        providers.save(ollama, key: nil)
        Accent.current = .ice
        return Rig(
            summarizer: MeetingSummarizer(store: store, providers: providers, settings: settings, router: router, local: model, now: { Date(timeIntervalSince1970: 9_000) }),
            store: store, providers: providers, settings: settings, network: network, model: model, transport: transport, meeting: meeting.id, raw: raw)
    }

    // MARK: nothing happens until Summarize

    @Test func noSummaryIsMadeWithoutPressingSummarize() async {
        // Record and transcribe a meeting, end to end.
        let defaults = UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let store = MeetingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("murmur-summary-tests-\(UUID().uuidString)"))
        let providers = ProviderStore(defaults: defaults, keys: MemoryKeyStore())
        let transport = SummaryFakeTransport(), model = SummaryFakeModel()
        let router = CleanupRouter(local: nil, providers: providers, settings: settings, transport: transport, network: nil)
        let summarizer = MeetingSummarizer(store: store, providers: providers, settings: settings, router: router, local: model)
        let controller = MeetingController(audio: DemoMeetingAudio(), engine: DemoEngine(), store: store, settings: settings, permissions: DemoPermissions()) { _ in DemoMeetingTrack() }
        controller.start()
        controller.stop()
        await controller.pendingWork?.value
        let meeting = store.meetings[0]
        #expect(meeting.isTranscribed && !meeting.lines.isEmpty)
        // Transcribed, and that is all: no summary, no model asked, nothing sent.
        #expect(meeting.summary == nil && summarizer.state == .idle && summarizer.pendingWork == nil)
        #expect(model.prompts.isEmpty && transport.sent.isEmpty)
        // Looking at the choices does not start one either.
        _ = summarizer.choices
        _ = summarizer.preselected
        #expect(store.meetings[0].summary == nil && model.prompts.isEmpty)
        Accent.current = .ice
    }

    // MARK: the transcript is the source of truth

    @Test func theRawTranscriptIsUnchangedAfterSummarizingAndAfterDeletingTheSummary() async {
        let rig = rig()
        let before = rig.store.meeting(rig.meeting)!
        rig.summarizer.summarize(rig.meeting, with: .apple)
        await rig.summarizer.pendingWork?.value
        var after = rig.store.meeting(rig.meeting)!
        #expect(after.summary?.text.hasPrefix("Key points") == true)
        #expect(after.lines == rig.raw && after.lines == before.lines && after.engine == before.engine && after.title == before.title)

        // Regenerating replaces the summary and nothing else.
        rig.summarizer.summarize(rig.meeting, with: .apple)
        await rig.summarizer.pendingWork?.value
        #expect(rig.store.meeting(rig.meeting)?.lines == rig.raw)

        rig.summarizer.deleteSummary(rig.meeting)
        after = rig.store.meeting(rig.meeting)!
        #expect(after.summary == nil && after == before)
        // And on disk, after a relaunch.
        let reopened = MeetingStore(directory: rig.store.directory)
        #expect(reopened.meetings[0].lines == rig.raw && reopened.meetings[0].summary == nil)
    }

    @Test func aSummarySurvivesARelaunchBesideTheTranscript() async {
        let rig = rig()
        rig.summarizer.summarize(rig.meeting, with: .apple)
        await rig.summarizer.pendingWork?.value
        let reopened = MeetingStore(directory: rig.store.directory).meetings[0]
        #expect(reopened.summary == MeetingSummary(text: "Key points\n- point 1\n\nAction items\n- None mentioned", provider: "Apple Intelligence", isLocal: true, date: Date(timeIntervalSince1970: 9_000)))
        #expect(reopened.summary?.byline == "Summary by Apple Intelligence · on this Mac" && reopened.lines == rig.raw)
    }

    // MARK: providers

    @Test func theChoicesListLocalProvidersFirstAndStartOnTheCleanupProvider() {
        let rig = rig()
        #expect(rig.summarizer.choices.map(\.id) == [ProviderConfig.appleID, "ollama", "cloud"])
        #expect(rig.summarizer.preselected.id == ProviderConfig.appleID)
        rig.providers.select("ollama")
        #expect(rig.summarizer.preselected.id == "ollama")
        #expect(cloud.recipient == "OpenAI" && ollama.recipient == ollama.hostLabel)
    }

    @Test func aCloudProviderNeedsConsentOnceAndNothingIsSentBeforeIt() async {
        let rig = rig()
        #expect(rig.summarizer.needsConsent(cloud) && !rig.summarizer.needsConsent(ollama) && !rig.summarizer.needsConsent(.apple))
        // Pressed without consent (the interface shows the sheet instead): refused, nothing sent.
        rig.summarizer.summarize(rig.meeting, with: cloud)
        await rig.summarizer.pendingWork?.value
        #expect(rig.transport.sent.isEmpty && rig.store.meeting(rig.meeting)?.summary == nil)
        if case .failed = rig.summarizer.state {} else { Issue.record("expected a visible failure") }

        // Agreeing remembers the address without changing the AI Cleanup choice.
        rig.summarizer.grantConsent(cloud)
        #expect(!rig.summarizer.needsConsent(cloud) && rig.providers.selectedID == ProviderConfig.appleID)
        rig.summarizer.summarize(rig.meeting, with: cloud)
        await rig.summarizer.pendingWork?.value
        let summary = rig.store.meeting(rig.meeting)?.summary
        #expect(summary?.provider == "OpenAI" && summary?.isLocal == false && summary?.byline == "Summary · via OpenAI")
        #expect(rig.transport.sent.count == 1 && rig.transport.sent[0].contains("line 0"))
    }

    @Test func aCloudSummaryIsWrittenToTheNetworkLog() async {
        let rig = rig()
        rig.summarizer.grantConsent(cloud)
        rig.summarizer.summarize(rig.meeting, with: cloud)
        await rig.summarizer.pendingWork?.value
        // The log line is written on the main actor just after the request.
        for _ in 0..<50 where rig.network.entries.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        let entry = rig.network.entries.first
        #expect(entry?.reason == "Meeting summary · OpenAI" && entry?.host == "api.openai.com" && entry?.isProvider == true && entry?.isLocal == false)
        #expect((entry?.bytes ?? 0) > 0)
    }

    @Test func offlineModeKeepsTheTranscriptAwayFromTheCloud() async {
        let rig = rig()
        rig.summarizer.grantConsent(cloud)
        rig.settings.offlineMode = true
        #expect(rig.summarizer.unavailableReason(cloud) == "Offline mode is on" && rig.summarizer.unavailableReason(ollama) == nil)
        rig.summarizer.summarize(rig.meeting, with: cloud)
        await rig.summarizer.pendingWork?.value
        #expect(rig.transport.sent.isEmpty && rig.store.meeting(rig.meeting)?.summary == nil)
    }

    @Test func aLocalServerSummaryStaysOnThisMac() async {
        let rig = rig()
        rig.summarizer.summarize(rig.meeting, with: ollama)
        await rig.summarizer.pendingWork?.value
        let summary = rig.store.meeting(rig.meeting)?.summary
        #expect(summary?.isLocal == true && summary?.byline == "Summary by Ollama · on this Mac")
    }

    @Test func aFailureIsShownAndLeavesAnyEarlierSummaryAlone() async {
        let rig = rig()
        rig.summarizer.summarize(rig.meeting, with: .apple)
        await rig.summarizer.pendingWork?.value
        let first = rig.store.meeting(rig.meeting)?.summary
        rig.model.fails = true
        rig.summarizer.summarize(rig.meeting, with: .apple)
        await rig.summarizer.pendingWork?.value
        #expect(rig.summarizer.state == .failed(id: rig.meeting, message: "Apple Intelligence couldn’t summarize this meeting."))
        #expect(rig.store.meeting(rig.meeting)?.summary == first && rig.store.meeting(rig.meeting)?.lines == rig.raw)

        rig.model.availability = .unavailable("Apple Intelligence is turned off in System Settings")
        #expect(rig.summarizer.unavailableReason(.apple) == "Apple Intelligence is turned off in System Settings")
    }

    // MARK: long meetings

    @Test func chunksKeepLinesWholeAndStayUnderTheLimit() {
        let lines = (0..<40).map { "You: line number \($0) of the meeting" }
        let chunks = SummaryChunker.chunks(lines, limit: 300)
        #expect(chunks.count > 1 && chunks.allSatisfy { $0.count <= 300 })
        #expect(chunks.joined(separator: "\n") == lines.joined(separator: "\n"))
        #expect(SummaryChunker.chunks(lines, limit: 100_000).count == 1)
        // One enormous line is cut rather than sent whole.
        let long = SummaryChunker.chunks([String(repeating: "a", count: 950)], limit: 400)
        #expect(long.map(\.count) == [400, 400, 150])
        #expect(SummaryChunker.chunks([], limit: 400).isEmpty)
    }

    @Test func aMeetingLongerThanTheModelsContextIsSummarizedInPartsThenCombined() async {
        // About 21,000 characters of transcript; Apple Intelligence takes 5,000 at a time.
        let rig = rig(lines: 300)
        var steps: [MeetingSummarizer.State] = []
        rig.model.onCall = { steps.append(rig.summarizer.state) }
        rig.summarizer.summarize(rig.meeting, with: .apple)
        await rig.summarizer.pendingWork?.value
        let prompts = rig.model.prompts
        #expect(prompts.count >= 5)
        // Every part but the last is asked as "part i of n"; the last request merges the part summaries.
        #expect(prompts.dropLast().allSatisfy { $0.system.contains("of a long meeting transcript") && $0.user.count <= 5_100 })
        #expect(prompts.last?.system.contains("Merge them") == true && prompts.last?.user.contains("Part 1:") == true)
        // Every line of the transcript went to the model exactly once.
        let sent = prompts.dropLast().map(\.user).joined()
        #expect((0..<300).allSatisfy { sent.contains("line \($0) uh") })
        #expect(rig.store.meeting(rig.meeting)?.summary != nil && rig.store.meeting(rig.meeting)?.lines == rig.raw)
        // Progress was reported along the way.
        #expect(steps == (0..<prompts.count).map { MeetingSummarizer.State.working(id: rig.meeting, step: $0, of: prompts.count) })
    }

    @Test func aRequestRefusedAsTooLargeIsRetriedInSmallerPieces() async {
        let rig = rig(lines: 120)
        rig.summarizer.grantConsent(cloud)
        // The cloud guess is 240,000 characters; this "model" only takes about 6,000.
        rig.transport.limit = 6_000
        rig.summarizer.summarize(rig.meeting, with: cloud)
        await rig.summarizer.pendingWork?.value
        #expect(rig.store.meeting(rig.meeting)?.summary?.text.contains("from the cloud") == true)
        #expect(rig.transport.sent.count > 2)
    }
}
