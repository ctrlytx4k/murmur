@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import MurmurKit

@Suite struct MeetingAudioTests {
    private static let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!

    /// Runs `body` with a buffer list made of the given streams, each a run of float samples.
    private func withList<T>(_ streams: [(channels: UInt32, samples: [Float])], _ body: (UnsafePointer<AudioBufferList>) -> T) -> T {
        let list = AudioBufferList.allocate(maximumBuffers: streams.count)
        defer {
            for buffer in list { buffer.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (index, stream) in streams.enumerated() {
            let memory = UnsafeMutablePointer<Float>.allocate(capacity: stream.samples.count)
            memory.update(from: stream.samples, count: stream.samples.count)
            list[index] = AudioBuffer(mNumberChannels: stream.channels, mDataByteSize: UInt32(stream.samples.count * MemoryLayout<Float>.size), mData: memory)
        }
        return body(UnsafePointer(list.unsafeMutablePointer))
    }

    private func samples(_ buffer: AVAudioPCMBuffer?) -> [Float] {
        guard let buffer, let data = buffer.audioBufferList.pointee.mBuffers.mData else { return [] }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(buffer.frameLength) * Int(buffer.format.channelCount)))
    }

    @Test func theTapIsReadAsItIsWhenItIsTheOnlyStream() {
        let call: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        let heard = withList([(2, call)]) { list -> [Float] in
            let buffer = TapInput.buffer(from: list, format: Self.stereo)
            #expect(buffer?.frameLength == 3)
            return samples(buffer)
        }
        #expect(heard == call)
    }

    @Test func aHeadsetsOwnMicrophoneIsNotMistakenForTheCall() {
        // The output device is a headset: its microphone comes first, the tap last.
        let headsetMicrophone: [Float] = [0.9, 0.9, 0.9, 0.9]
        let call: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
        let heard = withList([(1, headsetMicrophone), (2, call)]) { list -> [Float] in
            let buffer = TapInput.buffer(from: list, format: Self.stereo)
            #expect(buffer?.frameLength == 4)
            return samples(buffer)
        }
        #expect(heard == call)
    }

    @Test func aListWithoutTheTapIsRefused() {
        let planar = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        #expect(withList([(1, [0.5, 0.5])]) { TapInput.buffer(from: $0, format: planar) == nil })
    }

    @Test func aTrackThatStartsLateIsPaddedSoBothTracksShareOneClock() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-audio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // One second of a steady tone at 48 kHz stereo, as a call would arrive.
        let source = folder.appendingPathComponent("source.caf"), target = folder.appendingPathComponent("track.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        tone.frameLength = 48_000
        for channel in 0..<2 {
            for frame in 0..<48_000 { tone.floatChannelData![channel][frame] = sinf(Float(frame) * 0.06) * 0.5 }
        }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: source, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: tone)
        }

        // The recording began two seconds before this track's first audio arrived.
        try LiveMeetingAudio.rewrite(source, to: target, started: ProcessInfo.processInfo.systemUptime - 2)
        let written = try AVAudioFile(forReading: target, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(written.processingFormat.sampleRate == 16_000)
        let seconds = Double(written.length) / 16_000
        #expect(seconds > 2.8 && seconds < 3.4)
        let buffer = AVAudioPCMBuffer(pcmFormat: written.processingFormat, frameCapacity: AVAudioFrameCount(written.length))!
        try written.read(into: buffer)
        let data = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        #expect(data[0..<Int(1.9 * 16_000)].allSatisfy { $0 == 0 })
        #expect(data[Int(2.3 * 16_000)...].contains { abs($0) > 0.2 })
    }
}
