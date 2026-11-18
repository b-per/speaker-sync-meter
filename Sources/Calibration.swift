import Accelerate
import Foundation

enum CalibrationError: LocalizedError {
    case problem(String)

    var errorDescription: String? {
        switch self {
        case .problem(let message): return message
        }
    }
}

enum Probe {
    static let interval = 0.75
    static let duration = 0.046

    static func chirp(rate: Double) -> [Float] {
        (0..<Int(duration * rate)).map { index in
            let t = Double(index) / rate
            let ramp = min(1, min(t, duration - t) / 0.004)
            let envelope = 0.5 - 0.5 * cos(.pi * ramp)
            let phase = 2 * Double.pi * (700 * t + 0.5 * (3500 - 700) / duration * t * t)
            return Float(0.48 * envelope * sin(phase))
        }
    }

    static func writeTrack(to url: URL) throws {
        let rate = 48_000
        let repeats = 320
        let frames = Int(Double(rate) * interval)
        var block = Data(capacity: frames * 2)
        for sample in chirp(rate: Double(rate)) {
            block.appendLE(Int16((sample * Float(Int16.max)).rounded()))
        }
        block.append(Data(count: frames * 2 - block.count))

        var info = Data("INFO".utf8)
        for (tag, value) in [("INAM", "Speaker Sync Calibration"), ("IART", "Speaker Sync")] {
            info.append(Data(tag.utf8))
            let size = value.utf8.count + 1
            info.appendLE(UInt32(size))
            info.append(Data(value.utf8))
            info.append(Data(count: 1 + size % 2))
        }

        let audioSize = block.count * repeats
        var wav = Data("RIFF".utf8)
        wav.appendLE(UInt32(36 + 8 + info.count + audioSize))
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1))
        wav.appendLE(UInt16(1))
        wav.appendLE(UInt32(rate))
        wav.appendLE(UInt32(rate * 2))
        wav.appendLE(UInt16(2))
        wav.appendLE(UInt16(16))
        wav.append(Data("LIST".utf8))
        wav.appendLE(UInt32(info.count))
        wav.append(info)
        wav.append(Data("data".utf8))
        wav.appendLE(UInt32(audioSize))
        wav.reserveCapacity(wav.count + audioSize)
        for _ in 0..<repeats { wav.append(block) }
        try wav.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var bytes = value.littleEndian
        Swift.withUnsafeBytes(of: &bytes) { append(contentsOf: $0) }
    }
}

struct Recording {
    var samples: [Float]
    let sampleRate: Double
    let firstFrame: Int64
}

struct AcousticProfile {
    let sampleRate: Double
    // Correlation waveforms centered on the strongest arrival, averaged over multiple pulses.
    let average: [Float]
    let firstHalf: [Float]
    let secondHalf: [Float]
    let phase: Double
    let pulseCount: Int

    var center: Int { average.count / 2 }
}

struct DelayEstimate {
    let residualMs: Double  // Sonos arrival minus Nest arrival.
    let repeatDifferenceMs: Double
    let pulseCount: Int
    let overlapping: Bool

    func recommendedSetting(current: Int) -> Int? {
        let recommended = overlapping ? current : Int((Double(current) - residualMs).rounded())
        return (-500...500).contains(recommended) ? recommended : nil
    }
}

enum DelayAnalyzer {
    static let captureSeconds = 6.0

    static func profile(_ recording: Recording) throws -> AcousticProfile {
        let usefulRate = 12_000.0
        let inputRate = recording.sampleRate
        guard inputRate.isFinite, (8_000...384_000).contains(inputRate),
              recording.samples.count >= Int(inputRate * 5) else {
            throw CalibrationError.problem("The microphone capture was too short or used an unsupported sample rate. Try again.")
        }

        let factor = max(1, Int((inputRate / usefulRate).rounded()))
        let rate = inputRate / Double(factor)
        let clipped = vDSP.countElements(in: recording.samples, above: 0.995)
        guard clipped < recording.samples.count / 1000 else {
            throw CalibrationError.problem("The microphone clipped. Lower both speakers and start a new measurement.")
        }

        var samples = [Float](repeating: 0, count: recording.samples.count / factor)
        vDSP_desamp(recording.samples, vDSP_Stride(factor),
                    [Float](repeating: 1 / Float(factor), count: factor),
                    &samples, vDSP_Length(samples.count), vDSP_Length(factor))

        let chirp = unitVector(Probe.chirp(rate: rate))
        let matched = correlate(samples, with: chirp)
        let radius = Int((0.165 * rate).rounded())
        let period = Probe.interval * rate
        let slack = Int((0.0035 * rate).rounded())
        let interior = radius..<(matched.count - radius)
        guard let anchor = interior.max(by: { abs(matched[$0]) < abs(matched[$1]) }),
              abs(matched[anchor]) > 0.0004 else {
            throw noProbe
        }

        var peaks: [(frame: Int, cycle: Int)] = []
        for cycle in -Int(captureSeconds / Probe.interval)...Int(captureSeconds / Probe.interval) {
            let expected = anchor + Int((Double(cycle) * period).rounded())
            let search = max(interior.lowerBound, expected - slack)..<max(
                max(interior.lowerBound, expected - slack),
                min(interior.upperBound, expected + slack + 1)
            )
            guard let pick = search.max(by: { abs(matched[$0]) < abs(matched[$1]) }),
                  abs(matched[pick]) >= 0.24 * abs(matched[anchor]),
                  matched[pick] * matched[anchor] > 0 else { continue }
            let energy = samples.withUnsafeBufferPointer { buffer -> Float in
                var sum: Float = 0
                vDSP_svesq(buffer.baseAddress! + pick, 1, &sum, vDSP_Length(chirp.count))
                return sum
            }
            if abs(matched[pick]) >= 0.12 * sqrt(energy) { peaks.append((pick, cycle)) }
        }
        guard peaks.count >= 5 else { throw noProbe }

        let positions = peaks.map { Double($0.frame) - Double($0.cycle) * period }
        let zero = median(positions)
        guard positions.allSatisfy({ abs($0 - zero) / rate < 0.0016 }) else {
            throw CalibrationError.problem("The test pulses shifted during capture. Wait for playback to settle and retry this sample.")
        }

        let firstHalf = averageProfile(matched, around: peaks.prefix(peaks.count / 2).map(\.frame), radius: radius)
        let secondHalf = averageProfile(matched, around: peaks.suffix(peaks.count - peaks.count / 2).map(\.frame), radius: radius)
        return AcousticProfile(
            sampleRate: rate,
            average: zip(firstHalf, secondHalf).map { ($0 + $1) * 0.5 },
            firstHalf: firstHalf,
            secondHalf: secondHalf,
            phase: wrap(Double(recording.firstFrame) / inputRate + zero / rate),
            pulseCount: peaks.count
        )
    }

    static func estimate(both: AcousticProfile, reference: AcousticProfile, target: AcousticProfile) throws -> DelayEstimate {
        let rate = both.sampleRate
        guard reference.sampleRate == rate, target.sampleRate == rate else {
            throw CalibrationError.problem("The microphone sample rate changed. Start a new measurement.")
        }

        let lead = frames(0.004, rate)
        let tail = frames(0.035, rate)

        let referenceArrival = firstArrival(reference)
        let targetArrival = firstArrival(target)
        let referenceExpected = frames(wrap(reference.phase - both.phase), rate) + referenceArrival - reference.center
        let targetExpected = frames(wrap(target.phase - both.phase), rate) + targetArrival - target.center
        let estimatedResidualMs = Double(targetExpected - referenceExpected) * 1000 / rate
        guard abs(estimatedResidualMs) <= 120,
              max(abs(referenceExpected), abs(targetExpected)) <= frames(0.12, rate) else {
            throw CalibrationError.problem("The arrivals were outside the ±120 ms measurement range, or the track restarted. Keep the group playing and start a new measurement.")
        }

        let a = unitVector(Array(reference.average[(referenceArrival - lead)...(referenceArrival + tail)]))
        let b = unitVector(Array(target.average[(targetArrival - lead)...(targetArrival + tail)]))
        let overlap = correlate([Float](repeating: 0, count: b.count - 1) + a
                                + [Float](repeating: 0, count: b.count - 1), with: b)

        let inputs = FitInputs(
            a: a, b: b, overlap: overlap,
            referencePosition: both.center + referenceExpected - lead,
            targetPosition: both.center + targetExpected - lead,
            searchRadius: frames(0.007, rate),
            separationTolerance: frames(0.0015, rate),
            overlapTolerance: frames(0.001, rate)
        )

        let fits = [both.average, both.firstHalf, both.secondHalf].map(inputs.fit)
        let pulseCount = both.pulseCount + reference.pulseCount + target.pulseCount
        if fits.allSatisfy({ $0.overlapping }), abs(estimatedResidualMs) <= 1.2 {
            return DelayEstimate(residualMs: 0, repeatDifferenceMs: 0, pulseCount: pulseCount, overlapping: true)
        }

        guard let full = fits[0].separation,
              let first = fits[1].separation,
              let second = fits[2].separation else {
            throw CalibrationError.problem("The combined sound did not clearly match both speakers. Give them similar loudness at the Mac, check the solo samples, and try again.")
        }
        let difference = Double(abs(first - second)) * 1000 / rate
        guard difference <= 1.5,
              abs(Double(full - first)) * 1000 / rate <= 1.5,
              abs(Double(full - second)) * 1000 / rate <= 1.5 else {
            throw CalibrationError.problem("The delay varied between pulses. Let the group settle or try a quieter spot and measure again.")
        }
        return DelayEstimate(residualMs: Double(full) * 1000 / rate, repeatDifferenceMs: difference,
                             pulseCount: pulseCount, overlapping: false)
    }

    private static var noProbe: CalibrationError {
        .problem("Could not hear enough calibration pulses. Play the supplied WAV through the group, raise the active speaker to a comfortable level, and retry this sample.")
    }

    private static func firstArrival(_ profile: AcousticProfile) -> Int {
        let signal = profile.average
        let center = profile.center
        let lower = center - frames(0.013, profile.sampleRate)
        let upper = center - frames(0.00095, profile.sampleRate)
        let minimum = 0.46 * abs(signal[center])
        return (lower...upper).first {
            abs(signal[$0]) >= minimum && abs(signal[$0]) >= abs(signal[$0 - 1])
                && abs(signal[$0]) > abs(signal[$0 + 1])
        } ?? center
    }

    private static func averageProfile(_ values: [Float], around peaks: [Int], radius: Int) -> [Float] {
        var sum = [Float](repeating: 0, count: 2 * radius + 1)
        for peak in peaks {
            for index in sum.indices { sum[index] += values[peak - radius + index] }
        }
        return sum.map { $0 / Float(peaks.count) }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return (sorted[(sorted.count - 1) / 2] + sorted[middle]) * 0.5
    }
}

private struct FitInputs {
    let a: [Float]
    let b: [Float]
    let overlap: [Float]
    let referencePosition: Int
    let targetPosition: Int
    let searchRadius: Int
    let separationTolerance: Int
    let overlapTolerance: Int

    struct Result {
        var separation: Int?
        var overlapping = false
    }

    private struct Candidate {
        let aPosition: Int
        let bPosition: Int
        let energy: Float

        var separation: Int { bPosition - aPosition }
    }

    func fit(_ signal: [Float]) -> Result {
        let fitStart = min(referencePosition, targetPosition) - searchRadius
        let fitEnd = max(referencePosition, targetPosition) + searchRadius + a.count
        guard fitStart >= 0, fitEnd <= signal.count else { return Result() }
        let fitted = Array(signal[fitStart..<fitEnd])
        let inputEnergy = power(fitted)
        let aDot = correlate(fitted, with: a)
        let bDot = correlate(fitted, with: b)
        let aRange = (referencePosition - searchRadius - fitStart)...(referencePosition + searchRadius - fitStart)
        let bRange = (targetPosition - searchRadius - fitStart)...(targetPosition + searchRadius - fitStart)
        let aBest = aRange.max(by: { aDot[$0] < aDot[$1] })!
        let bBest = bRange.max(by: { bDot[$0] < bDot[$1] })!
        let singleA = max(0, aDot[aBest])
        let singleB = max(0, bDot[bBest])
        let singleEnergy = max(singleA * singleA, singleB * singleB)

        var candidates: [Candidate] = []
        for aIndex in aRange {
            for bIndex in bRange {
                let overlapIndex = a.count - 1 + bIndex - aIndex
                let cross = overlap.indices.contains(overlapIndex) ? overlap[overlapIndex] : 0
                let determinant = 1 - cross * cross
                if determinant < 0.025 { continue }
                // Solve the two-template least-squares fit with positive acoustic gains.
                let x = (aDot[aIndex] - cross * bDot[bIndex]) / determinant
                let y = (bDot[bIndex] - cross * aDot[aIndex]) / determinant
                if min(x, y) < 0.12 * max(x, y) || min(x, y) <= 0 { continue }
                let energy = x * aDot[aIndex] + y * bDot[bIndex]
                candidates.append(Candidate(aPosition: aIndex, bPosition: bIndex, energy: energy))
            }
        }

        let best = candidates.max(by: { $0.energy < $1.energy })
        if abs(targetPosition - referencePosition) <= overlapTolerance,
           abs(aBest - bBest) <= overlapTolerance,
           min(singleA * singleA, singleB * singleB) >= 0.83 * inputEnergy,
           (best?.energy ?? singleEnergy) - singleEnergy < 0.025 * inputEnergy {
            return Result(overlapping: true)
        }

        guard let best, best.energy >= 0.62 * inputEnergy,
              best.energy - singleEnergy >= 0.012 * inputEnergy else { return Result() }

        let plausible = candidates.filter { $0.energy >= best.energy - 0.018 * inputEnergy }
        let preferred = plausible.min { distance($0, fitStart: fitStart) < distance($1, fitStart: fitStart) }!
        let contenders = plausible.filter {
            distance($0, fitStart: fitStart) <= distance(preferred, fitStart: fitStart) + separationTolerance
        }
        guard contenders.allSatisfy({ abs($0.separation - preferred.separation) <= separationTolerance }) else {
            return Result()
        }
        // Use the strongest combined fit within the supported timing cluster.
        let measured = contenders.max(by: { $0.energy < $1.energy })!
        return Result(separation: measured.separation)
    }

    private func distance(_ candidate: Candidate, fitStart: Int) -> Int {
        abs(candidate.aPosition + fitStart - referencePosition)
            + abs(candidate.bPosition + fitStart - targetPosition)
    }
}

private func frames(_ seconds: Double, _ rate: Double) -> Int {
    Int((seconds * rate).rounded())
}

private func wrap(_ time: Double) -> Double {
    time - (time / Probe.interval).rounded() * Probe.interval
}

private func power(_ signal: [Float]) -> Float {
    var energy: Float = 0
    vDSP_svesq(signal, 1, &energy, vDSP_Length(signal.count))
    return energy
}

private func unitVector(_ signal: [Float]) -> [Float] {
    var level = max(1e-10, sqrt(power(signal)))
    var result = [Float](repeating: 0, count: signal.count)
    vDSP_vsdiv(signal, 1, &level, &result, 1, vDSP_Length(signal.count))
    return result
}

private func correlate(_ signal: [Float], with template: [Float]) -> [Float] {
    var values = [Float](repeating: 0, count: signal.count - template.count + 1)
    vDSP_conv(signal, 1, template, 1, &values, 1, vDSP_Length(values.count), vDSP_Length(template.count))
    return values
}

private extension vDSP {
    static func countElements(in samples: [Float], above threshold: Float) -> Int {
        samples.reduce(into: 0) { count, sample in
            if abs(sample) > threshold { count += 1 }
        }
    }
}
