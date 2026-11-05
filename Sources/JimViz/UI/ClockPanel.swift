import SwiftUI

/// The Clock input: tempo, tap, beat position and clock source. The clock always runs;
/// this device puts its controls and outputs (Pulse, ramps, Track Change, shown in the
/// inspector) in the scene. Its settings are global, not per scene.
struct ClockDevice: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        @Bindable var engine = engine
        @Bindable var state = engine.clockState
        DevicePanel(title: "Clock", subtitle: state.active.label, statusColor: dotColor(state),
                    select: "clock", settings: AnyView(ClockSettings(state: state)),
                    settingsHelp: "Latency and audio tempo range", onClose: { engine.removeInput("clock") }) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        TextField("BPM", value: $engine.bpm, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 54)
                            .multilineTextAlignment(.trailing)
                            .help("Current tempo. Typing a tempo switches to the manual clock.")
                        Text("BPM").font(Theme.labelFont).foregroundStyle(Theme.textDim)
                        Spacer(minLength: 0)
                        Button("Tap") { engine.tap() }
                            .controlSize(.small)
                            .help("Tap tempo (⌥⌘T). Tap three or more times on the beat. Switches to the manual clock.")
                    }
                    HStack(spacing: 6) {
                        BeatLights(beat: engine.beatInBar)
                            .onTapGesture { engine.resync() }
                            .help("Beat position. Click to snap to the next downbeat (⌥⌘D).")
                        Text("\(engine.bar + 1).\(engine.beatInBar + 1)")
                            .font(Theme.valueFont)
                            .foregroundStyle(Theme.textDim)
                    }
                    Picker("", selection: $state.mode) {
                        ForEach(ClockMode.allCases) { Text($0.shortLabel).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .help("Auto follows the audio's beat when it's steady and falls back to manual. Audio and Manual lock to one source.")
                    Text(status(state))
                        .font(Theme.labelFont)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 156)
        }
    }

    private func status(_ state: ClockState) -> String {
        if state.audioBPM == 0 { return state.mode == .manual ? "Manual tempo" : "Listening for a beat" }
        let conf = Int(state.audioConfidence * 100)
        return String(format: "Audio %.1f BPM, %d%%", state.audioBPM, conf)
    }

    private func dotColor(_ state: ClockState) -> Color {
        switch state.active {
        case .audio: return Theme.beatOn
        case .manual: return state.mode == .manual ? Theme.text : Theme.accent
        }
    }
}

struct BeatLights: View {
    let beat: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i == beat ? (i == 0 ? Theme.beatDownbeat : Theme.beatOn) : Theme.knobTrack)
                    .frame(width: 14, height: 9)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The clock's less-used settings, in a popover from the Clock device.
struct ClockSettings: View {
    @Bindable var state: ClockState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(modeHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                sourceRow(.audio, healthy: state.audioUsable, detail: audioDetail)
                sourceRow(.manual, healthy: true, detail: "Tap or type a tempo. Follows audio when available.")
            }

            Divider()

            LabeledContent("Latency") {
                HStack {
                    Slider(value: $state.latencyMs, in: -100...250, step: 5).frame(width: 160)
                    Text("\(Int(state.latencyMs)) ms").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            .help("Shifts the visuals earlier to make up for projector and audio delay. Increase it if visuals land after the kick.")

            LabeledContent("Audio tempo range") {
                HStack(spacing: 4) {
                    TextField("", value: $state.minBPM, format: .number).frame(width: 44)
                    Text("–")
                    TextField("", value: $state.maxBPM, format: .number).frame(width: 44)
                    Text("BPM").foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
            }
            .help("Keep this to one octave (max = 2 × min) so half- and double-time can't be confused.")
        }
        .padding(14)
        .frame(width: 360)
    }

    private var modeHelp: String {
        switch state.mode {
        case .auto: return "Auto: follows audio analysis when a steady beat is heard; falls back to manual tempo when quiet."
        case .audio: return "Audio: locked to audio tempo analysis only."
        case .manual: return "Manual: locked to manual tempo (tap or typed BPM)."
        }
    }

    private var audioDetail: String {
        if state.audioBPM == 0 { return "Listening for a steady beat." }
        let conf = Int(state.audioConfidence * 100)
        return state.audioUsable
            ? String(format: "%.1f BPM, confidence %d%%", state.audioBPM, conf)
            : String(format: "Analyzing (%.1f BPM, confidence %d%%)", state.audioBPM, conf)
    }

    private func sourceRow(_ kind: ClockSourceKind, healthy: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(healthy ? Theme.beatOn : Theme.knobTrack)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(kind.label).font(.system(size: 12, weight: .semibold))
                    if state.active == kind {
                        Text("ACTIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
