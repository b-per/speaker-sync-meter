import AVFoundation
import Foundation

/// All calls are on the main thread. The audio tap only copies the first input channel.
final class Microphone {
    private let engine = AVAudioEngine()
    private var active: Capture?
    private var nextFrame: Int64?
    private var sampleRate = 0.0
    private var tapID: UUID?
    private var discontinuity = false

    private struct Capture {
        let id: UUID
        let frameCount: Int
        let completion: (Result<Recording, Error>) -> Void
        var firstFrame: Int64?
        var samples: [Float] = []
    }

    func record(completion: @escaping (Result<Recording, Error>) -> Void) throws {
        if tapID == nil { try start() }
        guard !discontinuity, engine.isRunning else {
            throw CalibrationError.problem("The microphone stream changed. Start a new measurement using the same input.")
        }

        let id = UUID()
        let frameCount = Int(sampleRate * DelayAnalyzer.captureSeconds)
        active = Capture(id: id, frameCount: frameCount, completion: completion)
        active?.samples.reserveCapacity(frameCount)
        DispatchQueue.main.asyncAfter(deadline: .now() + DelayAnalyzer.captureSeconds + 5) { [weak self] in
            guard let self, self.active?.id == id else { return }
            self.finish(.failure(CalibrationError.problem("The microphone stopped providing audio. Start a new measurement.")))
        }
    }

    func stop() {
        if tapID != nil {
            tapID = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        active = nil
        nextFrame = nil
        discontinuity = false
    }

    private func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw CalibrationError.problem("No usable microphone input. Select MacBook Microphone in System Settings → Sound → Input.")
        }

        sampleRate = format.sampleRate
        let id = UUID()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            let stride = buffer.stride
            let samples = stride == 1
                ? Array(UnsafeBufferPointer(start: channel, count: count))
                : (0..<count).map { channel[$0 * stride] }
            let timestamp = time.isSampleTimeValid ? time.sampleTime : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.tapID == id else { return }
                self.consume(samples, firstFrame: timestamp)
            }
        }

        do {
            try engine.start()
            tapID = id
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func consume(_ samples: [Float], firstFrame: Int64?) {
        guard !discontinuity else { return }
        guard let firstFrame, nextFrame == nil || nextFrame == firstFrame else {
            discontinuity = true
            finish(.failure(CalibrationError.problem("The microphone timeline was interrupted. Start a new measurement.")))
            return
        }
        nextFrame = firstFrame + Int64(samples.count)

        guard let frameCount = active?.frameCount, let collected = active?.samples.count else { return }
        if active?.firstFrame == nil { active?.firstFrame = firstFrame }
        let remaining = frameCount - collected
        append(samples.prefix(remaining))
    }

    private func append(_ samples: ArraySlice<Float>) {
        active?.samples.append(contentsOf: samples)
        if let active, active.samples.count == active.frameCount, let firstFrame = active.firstFrame {
            finish(.success(Recording(samples: active.samples, sampleRate: sampleRate, firstFrame: firstFrame)))
        }
    }

    private func finish(_ result: Result<Recording, Error>) {
        let completion = active?.completion
        active = nil
        completion?(result)
    }
}
