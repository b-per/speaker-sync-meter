import Foundation

@main
struct CalibrationChecks {
    // Run the same correlation and fit used by the GUI on synthetic mic recordings.
    static func main() throws {
        for rate in [44_100.0, 48_000.0] {
            for offset in [6.4, -4.2, 1.6, -1.1, 0.0, 29.5, -100.0] {
                let result = try trial(rate: rate, residualMs: offset)
                precondition(abs(result.residualMs - offset) <= 0.45, "Expected \(offset), measured \(result.residualMs) at \(rate)")
                precondition(result.recommendedSetting(current: 40) == Int((40 - offset).rounded()))
                print("\(Int(rate)) Hz · \(offset) ms expected · \(result.residualMs) ms measured · \(result.recommendedSetting(current: 40)!) ms setting")
            }
        }
        expectRejection("missing speaker") { try trial(rate: 48_000, residualMs: 6.4, targetGain: 0) }
        expectRejection("changed playback timeline") { try trial(rate: 48_000, residualMs: 6.4, targetTimelineShiftMs: 27) }
        expectRejection("unstable playback") { try trial(rate: 48_000, residualMs: 6.4, varyingDelayMs: 4) }
        expectRejection("silence") {
            try DelayAnalyzer.profile(Recording(samples: .init(repeating: 0, count: 288_000), sampleRate: 48_000, firstFrame: 0))
        }
        expectRejection("clipping") {
            try DelayAnalyzer.profile(Recording(samples: .init(repeating: 1, count: 288_000), sampleRate: 48_000, firstFrame: 0))
        }
        precondition(DelayEstimate(residualMs: -6, repeatDifferenceMs: 0, pulseCount: 18, overlapping: false)
            .recommendedSetting(current: 498) == nil)
    }

    private static func expectRejection<T>(_ name: String, _ run: () throws -> T) {
        do {
            _ = try run()
            preconditionFailure("Expected rejection for \(name)")
        } catch {
            print("Rejected \(name) · \(error.localizedDescription)")
        }
    }

    private static func trial(rate: Double, residualMs: Double, targetGain: Float = 0.72,
                              targetTimelineShiftMs: Double = 0, varyingDelayMs: Double = 0) throws -> DelayEstimate {
        let rateFrames = Int(rate.rounded())
        let source = Probe.chirp(rate: rate)
        var random: UInt32 = 53
        func capture(at time: Double, reference: Bool, target: Bool, combined: Bool) throws -> AcousticProfile {
            let start = Int((time * rate).rounded())
            var samples = (0..<(rateFrames * 6)).map { _ -> Float in
                random = 1_664_525 &* random &+ 1_013_904_223
                return 0.012 * (Float(random >> 8) / 16_777_215 - 0.5)
            }

            func add(at time: Double, level: Float, color: Float) {
                let first = Int((time * rate).rounded()) - start
                for index in source.indices {
                    let frame = first + index
                    if samples.indices.contains(frame) {
                        let previous = index > 0 ? source[index - 1] : 0
                        samples[frame] += level * (source[index] - color * previous)
                    }
                }
            }

            for cycle in 0..<80 {
                let playTime = 0.439 + Double(cycle) * Probe.interval
                if reference {
                    add(at: playTime, level: 0.82, color: 0.1)
                    add(at: playTime + 0.0051, level: 0.30, color: 0.1)
                    add(at: playTime + 0.0193, level: -0.16, color: 0.1)
                }
                if target {
                    let change = combined && playTime >= 5 ? varyingDelayMs : 0
                    let shift = combined ? 0 : targetTimelineShiftMs
                    let arrival = playTime + (residualMs + change + shift) / 1000
                    let gain: Float = combined ? targetGain : 0.72
                    add(at: arrival, level: gain, color: -0.12)
                    add(at: arrival + 0.0034, level: -0.35 * gain, color: -0.12)
                    add(at: arrival + 0.0127, level: 0.31 * gain, color: -0.12)
                }
            }
            return try DelayAnalyzer.profile(Recording(samples: samples, sampleRate: rate, firstFrame: Int64(start)))
        }

        let both = try capture(at: 1.097, reference: true, target: true, combined: true)
        let reference = try capture(at: 11.419, reference: true, target: false, combined: false)
        let target = try capture(at: 22.747, reference: false, target: true, combined: false)
        return try DelayAnalyzer.estimate(both: both, reference: reference, target: target)
    }
}
