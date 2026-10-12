import Foundation
import Observation

/// Whose words a line holds. Known only when the call was recorded on its own track:
/// the microphone is you, the call is everyone else. Telling the others apart comes later.
public nonisolated enum MeetingSpeaker: String, Codable, Sendable {
    case you, others

    public var label: String { self == .you ? "You" : "Others" }
}

public nonisolated struct MeetingLine: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// Seconds from the start of the recording.
    public var start: Double
    public var speaker: MeetingSpeaker?
    /// Which of the people on the call said it, numbered from 1 in the order they first spoke.
    /// Nil when the voices were not told apart.
    public var voice: Int?
    public var text: String

    public init(start: Double, speaker: MeetingSpeaker?, voice: Int? = nil, text: String) {
        self.start = start
        self.speaker = speaker
        self.voice = voice
        self.text = text
    }
}

/// A stretch of the call track in which one person speaks.
public nonisolated struct SpeakerTurn: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var voice: Int

    public init(start: Double, end: Double, voice: Int) {
        self.start = start
        self.end = end
        self.voice = voice
    }
}

/// Tells the people on the call apart by voice. Needs a small model that is downloaded once.
public protocol SpeakerSeparator: AnyObject {
    var isInstalled: Bool { get }
    func turns(in track: URL) async throws -> [SpeakerTurn]
}

public nonisolated enum SpeakerTurns {
    /// Turns ready to transcribe: neighbours by the same voice joined, scraps dropped, long ones cut,
    /// and the voices numbered from 1 in the order they first speak.
    public static func pieces(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var joined: [SpeakerTurn] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) where turn.end > turn.start {
            if let last = joined.last, last.voice == turn.voice, turn.start - last.end <= SpeechSegmenter.joinGap {
                joined[joined.count - 1].end = max(last.end, turn.end)
            } else {
                joined.append(turn)
            }
        }
        var numbers: [Int: Int] = [:]
        var pieces: [SpeakerTurn] = []
        for turn in joined where turn.end - turn.start >= 0.2 {
            let voice = numbers[turn.voice] ?? numbers.count + 1
            numbers[turn.voice] = voice
            let parts = max(1, Int(((turn.end - turn.start) / SpeechSegmenter.longest).rounded(.up)))
            let length = (turn.end - turn.start) / Double(parts)
            for part in 0..<parts {
                pieces.append(SpeakerTurn(start: turn.start + Double(part) * length, end: turn.start + Double(part + 1) * length, voice: voice))
            }
        }
        return pieces
    }
}

/// One recorded call. The transcript is the raw one, exactly as the engine heard it: it is written once
/// and never edited or cleaned afterwards. Anything derived from it is stored beside it, not over it.
public nonisolated struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var title: String
    public var date: Date
    public var duration: TimeInterval
    /// The call's own audio was recorded as well as the microphone.
    public var includesCallAudio: Bool
    public private(set) var lines: [MeetingLine] = []
    public private(set) var isTranscribed = false
    public private(set) var engine: String?
    /// Something the reader should know about this transcript, such as "no call audio was heard".
    public var note: String?
    /// Why it is not transcribed yet, after a failed attempt.
    public var problem: String?
    public var hasAudio = true
    /// Made only when the user asks for one. Lives beside the transcript and can be deleted on its own.
    public var summary: MeetingSummary?
    /// Names the user gave the voices on the call, by voice number. Labels only: the transcript's words never change.
    public var speakerNames: [String: String]?

    public init(id: UUID = UUID(), title: String, date: Date, duration: TimeInterval, includesCallAudio: Bool) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.includesCallAudio = includesCallAudio
    }

    /// Stores the raw transcript. Works once: a meeting that has a transcript keeps it, and this returns false.
    @discardableResult
    public mutating func setTranscript(_ lines: [MeetingLine], engine: String, note: String? = nil) -> Bool {
        guard !isTranscribed else { return false }
        self.lines = lines
        self.engine = engine
        self.note = note
        problem = nil
        isTranscribed = true
        return true
    }

    /// Who a line is shown as: "You", a name the user gave, "Speaker 2", or "Others" when the voices were not told apart.
    public func label(for line: MeetingLine) -> String? {
        guard let speaker = line.speaker else { return nil }
        guard speaker == .others, let voice = line.voice else { return speaker.label }
        return speakerNames?[String(voice)] ?? "Speaker \(voice)"
    }

    /// How many different voices were heard on the call.
    public var voiceCount: Int { Set(lines.compactMap(\.voice)).count }

    /// The transcript as plain text, one line per turn.
    public func text(clock: (Double) -> String) -> String {
        lines.map { line in "\(clock(line.start)) \(label(for: line).map { "\($0): " } ?? "")\(line.text)" }.joined(separator: "\n")
    }
}

/// Recorded meetings, newest first. Each one is a folder on this Mac holding `meeting.json` and, until
/// it is deleted, the audio. Nothing here goes anywhere else.
@Observable
public final class MeetingStore {
    @ObservationIgnored public let directory: URL
    public private(set) var meetings: [Meeting] = []
    /// Set when a meeting could not be written to disk, so the interface can say so.
    public private(set) var saveError: String?

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Murmur/Meetings", isDirectory: true)
    }

    public init(directory: URL = MeetingStore.defaultDirectory) {
        self.directory = directory
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        meetings = folders.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("meeting.json"))).flatMap { try? decoder.decode(Meeting.self, from: $0) }
        }
        .sorted { $0.date > $1.date }
    }

    public func folder(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func microphoneURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("microphone.caf") }
    public func callURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("call.caf") }

    public func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    /// Makes the folder a recording is written into.
    public func prepareFolder(for id: UUID) throws {
        try FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
    }

    public func add(_ meeting: Meeting) {
        meetings.insert(meeting, at: 0)
        meetings.sort { $0.date > $1.date }
        save(meeting)
    }

    public func rename(_ id: UUID, to title: String) {
        update(id) { $0.title = title }
    }

    /// Stores the raw transcript, once. Returns false, and changes nothing, if the meeting already has one.
    @discardableResult
    public func finishTranscription(_ id: UUID, lines: [MeetingLine], engine: String, note: String? = nil) -> Bool {
        var stored = false
        update(id) { stored = $0.setTranscript(lines, engine: engine, note: note) }
        return stored
    }

    /// Names one of the voices on the call. An empty name goes back to "Speaker 2".
    public func nameSpeaker(_ id: UUID, voice: Int, _ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { meeting in
            var names = meeting.speakerNames ?? [:]
            names[String(voice)] = name.isEmpty ? nil : name
            meeting.speakerNames = names.isEmpty ? nil : names
        }
    }

    /// Stores, replaces or (with nil) removes the summary. The transcript is not involved.
    public func setSummary(_ id: UUID, _ summary: MeetingSummary?) {
        update(id) { $0.summary = summary }
    }

    public func markFailed(_ id: UUID, problem: String) {
        update(id) { $0.problem = problem }
    }

    /// Removes the audio and keeps the transcript.
    public func deleteAudio(_ id: UUID) {
        try? FileManager.default.removeItem(at: microphoneURL(for: id))
        try? FileManager.default.removeItem(at: callURL(for: id))
        update(id) { $0.hasAudio = false }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
        meetings.removeAll { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        var meeting = meetings[index]
        change(&meeting)
        guard meeting != meetings[index] else { return }
        meetings[index] = meeting
        save(meeting)
    }

    private func save(_ meeting: Meeting) {
        do {
            try prepareFolder(for: meeting.id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(meeting).write(to: folder(for: meeting.id).appendingPathComponent("meeting.json"), options: .atomic)
            saveError = nil
        } catch {
            saveError = "Couldn’t save the meeting: \(error.localizedDescription)"
        }
    }
}

// MARK: services

public nonisolated struct MeetingRecording: Equatable, Sendable {
    public var duration: TimeInterval
    /// A call track was recorded, but it held nothing at all: usually System Audio Recording is off.
    public var callWasSilent: Bool

    public init(duration: TimeInterval, callWasSilent: Bool = false) {
        self.duration = duration
        self.callWasSilent = callWasSilent
    }
}

/// Records a meeting straight to files: the microphone on one track and, when asked, everything the Mac
/// plays on another. A call can run for hours, so the audio is never held in memory.
public protocol MeetingAudioService: AnyObject {
    /// `call` is nil for a microphone-only recording. `onLevel` reports the microphone, 0...1.
    func start(microphone: URL, call: URL?, microphoneID: String?, onLevel: @escaping (Float) -> Void) throws
    /// Closes the files. Safe to call while quitting.
    func stop() -> MeetingRecording
    /// Makes macOS show its System Audio Recording prompt, if it has not been answered yet.
    func requestSystemAudio()
}

/// One recorded track, read back for transcription a piece at a time. Reading happens off the main actor.
public nonisolated protocol MeetingTrack: Sendable {
    /// Loudness (RMS) of each `SpeechSegmenter.frame` of the track.
    func levels() async throws -> [Float]
    func clip(from start: Double, to end: Double) async throws -> AudioClip
}

// MARK: finding speech

/// Cuts a track into stretches of speech, so a long recording is transcribed turn by turn with a time on each.
public nonisolated enum SpeechSegmenter {
    /// Seconds per loudness frame.
    public static let frame = 0.02
    static let joinGap = 0.6
    static let shortest = 0.25
    static let padding = 0.15
    static let longest = 25.0

    public static func segments(levels: [Float]) -> [ClosedRange<Double>] {
        guard !levels.isEmpty else { return [] }
        // The quietest tenth of the track is the room, and speech has to stand clear of it. When someone talks
        // nearly all the time there is no quiet tenth, so the bar is never set above a quarter of the loud parts.
        let sorted = levels.sorted()
        let floor = sorted[levels.count / 10], loud = sorted[levels.count * 95 / 100]
        guard loud >= 0.006 else { return [] }
        let threshold = max(0.003, min(floor * 3, loud * 0.25))
        let gap = Int(joinGap / frame), pad = Int(padding / frame)

        var runs: [(start: Int, end: Int)] = []
        var index = 0
        while index < levels.count {
            guard levels[index] > threshold else { index += 1; continue }
            var end = index
            while end + 1 < levels.count, levels[end + 1] > threshold { end += 1 }
            if let last = runs.last, index - last.end <= gap { runs[runs.count - 1].end = end } else { runs.append((index, end)) }
            index = end + 1
        }

        var pieces: [(start: Int, end: Int)] = []
        for run in runs where Double(run.end - run.start + 1) * frame >= shortest {
            var start = max(run.start - pad, (pieces.last?.end ?? -1) + 1)
            let end = min(run.end + pad, levels.count - 1)
            // A long monologue is cut at its quietest moment, so no piece is too long for the engine.
            while Double(end - start + 1) * frame > longest {
                let from = start + Int(longest * 0.6 / frame), to = start + Int(longest / frame)
                let cut = (from...to).min { levels[$0] < levels[$1] } ?? to
                pieces.append((start, cut))
                start = cut + 1
            }
            pieces.append((start, end))
        }
        return pieces.map { Double($0.start) * frame...Double($0.end + 1) * frame }
    }
}

public nonisolated struct MeetingTranscriptionFailure: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
}

/// Turns a recording into the raw transcript: each stretch of speech goes to the engine as it is,
/// and comes back as one line. Nothing is cleaned, corrected or reworded.
public enum MeetingTranscriber {
    public struct Result: Equatable {
        public var lines: [MeetingLine]
        public var note: String?
    }

    /// `callTurns` are who spoke when on the call, when the voices were told apart. Without them the call is one "Others".
    public static func transcribe(
        microphone: (any MeetingTrack)?, call: (any MeetingTrack)?, callWasSilent: Bool = false, callTurns: [SpeakerTurn]? = nil,
        engine: any TranscriptionEngine, onProgress: (Double) -> Void
    ) async throws -> Result {
        switch engine.readiness {
        case .ready: break
        case .preparing(let name, _): throw MeetingTranscriptionFailure(message: "The speech model (\(name)) is still downloading.")
        case .unavailable(let reason): throw MeetingTranscriptionFailure(message: reason)
        }
        // With a call track the microphone is you and the call is everyone else. Without one, nobody is named.
        var jobs: [(track: any MeetingTrack, speaker: MeetingSpeaker?, voice: Int?, range: ClosedRange<Double>)] = []
        if let microphone {
            jobs += SpeechSegmenter.segments(levels: try await microphone.levels()).map { (microphone, call == nil ? nil : .you, nil, $0) }
        }
        if let call {
            let pieces = SpeakerTurns.pieces(callTurns ?? [])
            if pieces.isEmpty {
                jobs += SpeechSegmenter.segments(levels: try await call.levels()).map { (call, .others, nil, $0) }
            } else {
                jobs += pieces.map { (call, .others, $0.voice, $0.start...$0.end) }
            }
        }
        jobs.sort { $0.range.lowerBound < $1.range.lowerBound }

        let total = jobs.reduce(0) { $0 + ($1.range.upperBound - $1.range.lowerBound) }
        var done = 0.0
        var lines: [MeetingLine] = []
        onProgress(0)
        for job in jobs {
            try Task.checkCancellation()
            let clip = try await job.track.clip(from: job.range.lowerBound, to: job.range.upperBound)
            let text = try await engine.transcribe(clip).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(MeetingLine(start: job.range.lowerBound, speaker: job.speaker, voice: job.voice, text: text)) }
            done += job.range.upperBound - job.range.lowerBound
            onProgress(total > 0 ? done / total : 1)
        }
        var note: String?
        if callWasSilent {
            note = "No call audio was heard, so only your microphone is here. If other people spoke, check System Audio Recording in System Settings › Privacy & Security."
        } else if lines.isEmpty {
            note = "No speech was heard in this recording."
        }
        return Result(lines: lines, note: note)
    }
}
