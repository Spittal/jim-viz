import SwiftUI

/// The Clock input device: tempo, first beat, beat position and audio-following. Placed in the
/// scene's input chain. It follows audio only when Audio In's Audio Out is mapped into its
/// Audio input. Its knobs (latency, tempo range) are in the settings popover.
struct ClockDevice: View {
    @Environment(Engine.self) private var engine
    let clock: ClockRuntime
    var accent: Color? = nil

    var body: some View {
        let state = clock
        DevicePanel(title: "Clock", subtitle: state.active.label, statusColor: dotColor(state),
                    accent: accent,
                    select: "clock", settings: AnyView(ClockSettings(state: state)),
                    settingsHelp: "Latency and audio tempo range", onClose: { engine.removeInput("clock") }) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        TextField("BPM", value: Binding(get: { state.bpm }, set: { state.setManualBPM($0) }), format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 54)
                            .multilineTextAlignment(.trailing)
                            .help("Current tempo. Follows mapped audio when steady; otherwise the manual tempo typed here.")
                        Text("BPM").font(Theme.labelFont).foregroundStyle(Theme.textDim)
                    }
                    HStack(spacing: 6) {
                        BeatLights(beat: state.beatInBar)
                            .help("Beat position in the bar.")
                        Text("\(state.bar + 1).\(state.beatInBar + 1)")
                            .font(Theme.valueFont)
                            .foregroundStyle(Theme.textDim)
                    }
                    Button("First Beat") { state.firstBeat() }
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .help("Press on the first beat of a phrase. The nearest beat becomes bar 1, beat 1.")
                    Text(status(state))
                        .font(Theme.labelFont)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 156)
        }
    }

    private func status(_ state: ClockRuntime) -> String {
        if !state.hearsAudio { return "Manual tempo" }
        if state.audioBPM == 0 { return "Listening for a beat" }
        let conf = Int(state.audioConfidence * 100)
        return String(format: "Audio %.1f BPM, %d%%", state.audioBPM, conf)
    }

    private func dotColor(_ state: ClockRuntime) -> Color {
        switch state.active {
        case .audio: return Theme.beatOn
        case .manual: return state.hearsAudio ? Theme.accent : Theme.text
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

/// The clock's less-used settings, in a popover from the Clock device: source status and its
/// knobs, which belong to the scene's Clock and can be mapped like any other.
struct ClockSettings: View {
    let state: ClockRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                sourceRow(.audio, healthy: state.audioUsable, detail: audioDetail)
                sourceRow(.manual, healthy: true, detail: "Manual fallback tempo. Type a BPM.")
            }

            Divider()

            KnobGrid(params: state.bank.params, prefix: "clock")
            Text("Latency (ms) shifts the visuals earlier to make up for projector and audio delay: increase it if visuals land after the kick. Keep the audio tempo range to one octave (max = 2 × min) so half- and double-time can't be confused.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 360)
    }

    private var audioDetail: String {
        if !state.hearsAudio { return "Nothing mapped into the Clock's Audio input." }
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
