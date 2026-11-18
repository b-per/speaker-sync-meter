import AVFoundation
import SwiftUI

@main
private struct Launcher {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--write-track" {
            do {
                try Probe.writeTrack(to: URL(fileURLWithPath: arguments[2]))
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        SpeakerSyncApp.main()
    }
}

struct SpeakerSyncApp: App {
    var body: some Scene {
        Window("Speaker Sync", id: "calibration") {
            CalibrationView()
        }
        .windowResizability(.contentSize)
    }
}

private enum Step: Int, CaseIterable {
    case both, reference, target

    var title: String {
        switch self {
        case .both: return "Both speakers"
        case .reference: return "Nest only"
        case .target: return "Sonos only"
        }
    }

    var instructions: String {
        switch self {
        case .both:
            return "Play the calibration track on the Music Assistant group. Set the Nest and Sonos to comfortable, roughly equal loudness at the Mac."
        case .reference:
            return "Mute the Sonos or set its individual volume to zero. Keep the Nest at the same volume and leave the track playing."
        case .target:
            return "Restore the Sonos to its original volume, then mute the Nest or set its individual volume to zero. Keep the track playing."
        }
    }
}

private final class CalibrationModel: ObservableObject {
    @Published var currentSetting = "40"
    @Published private(set) var step: Step? = .both
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    @Published private(set) var estimate: DelayEstimate?
    @Published private(set) var hadFailure = false

    private let microphone = Microphone()
    private var profiles: [AcousticProfile] = []
    private var session = UUID()

    var setting: Int? {
        guard let value = Int(currentSetting.trimmingCharacters(in: .whitespaces)), (-500...500).contains(value) else {
            return nil
        }
        return value
    }

    func reset() {
        session = UUID()
        microphone.stop()
        profiles.removeAll()
        step = .both
        status = nil
        busy = false
        estimate = nil
        hadFailure = false
    }

    func exportTrack() {
        let dialog = NSSavePanel()
        dialog.nameFieldStringValue = "Speaker Sync Calibration.wav"
        if dialog.runModal() == .OK, let url = dialog.url {
            do {
                try Probe.writeTrack(to: url)
            } catch {
                status = "Could not save the calibration track. \(error.localizedDescription)"
            }
        }
    }

    func record() {
        guard let step, setting != nil, !busy else { return }
        status = nil
        busy = true
        let id = session

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: capture(step, session: id)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.session == id else { return }
                    if granted { self.capture(step, session: id) }
                    else { self.showPermissionMessage() }
                }
            }
        default: showPermissionMessage()
        }
    }

    private func showPermissionMessage() {
        status = "Allow Speaker Sync to use the microphone in System Settings → Privacy & Security → Microphone."
        busy = false
    }

    private func capture(_ step: Step, session id: UUID) {
        status = "Recording for 6 seconds…"
        do {
            try microphone.record { [weak self] result in
                guard let self, self.session == id else { return }
                do {
                    let recording = try result.get()
                    self.analyze(recording, step: step, session: id)
                } catch {
                    self.fail(error)
                }
            }
        } catch {
            fail(error)
        }
    }

    private func analyze(_ recording: Recording, step: Step, session id: UUID) {
        status = "Analyzing pulses…"
        let previous = profiles
        DispatchQueue.global(qos: .userInitiated).async {
            let profileResult = Result { try DelayAnalyzer.profile(recording) }
            let result = profileResult.flatMap { profile in
                Result { () -> (AcousticProfile, DelayEstimate?) in
                    guard step == .target else { return (profile, nil) }
                    let estimate = try DelayAnalyzer.estimate(both: previous[0], reference: previous[1], target: profile)
                    return (profile, estimate)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session == id else { return }
                switch result {
                case .success(let (profile, estimate)):
                    self.profiles.append(profile)
                    self.step = Step(rawValue: step.rawValue + 1)
                    self.estimate = estimate
                    self.status = nil
                    self.busy = false
                    if estimate != nil { self.microphone.stop() }
                case .failure(let error):
                    self.fail(error, restart: (try? profileResult.get()) != nil)
                }
            }
        }
    }

    private func fail(_ error: Error, restart: Bool = true) {
        status = error.localizedDescription
        busy = false
        hadFailure = restart
        if restart { microphone.stop() }
    }
}

private struct CalibrationView: View {
    @StateObject private var model = CalibrationModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speaker Sync")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Measure the Nest and Sonos at the Mac’s position.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Put the Mac midway between the speakers, or where you normally listen. Keep it in place until all three captures finish.")
                    Button("Save calibration track…", action: model.exportTrack)
                        .disabled(model.busy)
                    Text("Add the WAV to Music Assistant’s Local Files source. Keep the same group and playback running, and change only individual volumes during the captures.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Current Sonos AirPlay setting")
                        TextField("Current Sonos AirPlay setting", text: $model.currentSetting)
                            .labelsHidden()
                            .frame(width: 55)
                            .disabled(model.step != .both || model.busy)
                        Text("ms").foregroundStyle(.secondary)
                    }
                    if model.setting == nil {
                        Text("Enter the current setting as a whole number from −500 to +500 ms.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(5)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if let step = model.step {
                        Text("\(step.rawValue + 1) of 3 · \(step.title)")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(step.instructions)
                        if let status = model.status {
                            HStack(alignment: .firstTextBaseline) {
                                if model.busy { ProgressView().controlSize(.small) }
                                Text(status).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            if !model.hadFailure {
                                Button("Record \(step.title)", action: model.record)
                                    .buttonStyle(.borderedProminent)
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(model.busy || model.setting == nil)
                            }
                            if step != .both || model.busy || model.status != nil {
                                Button(model.busy ? "Cancel measurement" : "Start over", action: model.reset)
                                    .keyboardShortcut(.cancelAction)
                            }
                        }
                    } else if let estimate = model.estimate, let current = model.setting {
                        result(estimate, current: current)
                        Text("Restore the Nest’s volume. Apply the setting in Music Assistant, then start a new measurement to check it.")
                            .foregroundStyle(.secondary)
                        Button("Start new measurement", action: model.reset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(5)
            }
        }
        .padding(24)
        .frame(width: 555)
        .onDisappear(perform: model.reset)
    }

    @ViewBuilder
    private func result(_ estimate: DelayEstimate, current: Int) -> some View {
        if let setting = estimate.recommendedSetting(current: current) {
            Text(setting == current ? "Keep AirPlay at \(signed(setting)) ms" : "Set AirPlay to \(signed(setting)) ms")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        } else {
            Text("Required setting is outside ±500 ms")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
        if estimate.overlapping {
            Text("Arrivals overlap within about 1 ms at this position.")
        } else {
            let timing = estimate.residualMs < 0 ? "earlier" : "later"
            Text("Sonos arrived \(abs(estimate.residualMs).formatted(.number.precision(.fractionLength(1)))) ms \(timing) than Nest.")
            Text("The two halves differed by \(estimate.repeatDifferenceMs.formatted(.number.precision(.fractionLength(1)))) ms. \(estimate.pulseCount) pulses captured.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : String(value)
    }
}
