import SwiftUI

/// The Audio In device: source picker, status, meters, spectrum and its analysis knobs.
/// The source and channel pair are saved with the scene; the knobs are this scene's, and mappable.
struct AudioDevice: View {
    @Environment(Engine.self) private var engine
    let input: AudioInRuntime
    var accent: Color? = nil

    var body: some View {
        let audio = input.capture
        DevicePanel(title: "Audio In", subtitle: nil, statusColor: color(audio.health), accent: accent, select: "audio",
                    onClose: { engine.removeInput("audio") }) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    sourceMenu(audio)
                    if max(audio.channelPairs, audio.channelPair + 1) > 1 {
                        Picker("", selection: Binding(get: { audio.channelPair }, set: { engine.setAudioChannelPair($0) })) {
                            ForEach(0..<max(audio.channelPairs, audio.channelPair + 1), id: \.self) { i in
                                Text("Ch \(i * 2 + 1)–\(i * 2 + 2)\(i == 0 ? " (master)" : "")").tag(i)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 168)
                        .help("Which output channels to listen to. On a DDJ-FLX4, 1–2 is master and 3–4 is headphones.")
                    }
                    Text(audio.statusText)
                        .font(Theme.labelFont)
                        .foregroundStyle(audio.health == .error || audio.health == .silent ? Theme.error : Theme.textDim)
                        .lineLimit(3)
                        .frame(width: 168, height: 34, alignment: .topLeading)
                        .help(audio.statusText)
                    SpectrumView(bins: input.meters.spectrum)
                        .frame(width: 168, height: 40)
                    Meters(meters: input.meters)
                }
                KnobGrid(params: input.bank.params, prefix: "audio")
            }
        }
    }

    private func sourceMenu(_ audio: AudioCapture) -> some View {
        let captures = engine.audioCaptures
        return Menu {
            Button("Rekordbox") { engine.setAudioSource(.rekordbox) }
            Button("System Audio") { engine.setAudioSource(.systemAudio) }
            Menu("Input Device") {
                ForEach(captures.inputDevices) { d in
                    Button(d.name) { engine.setAudioSource(.input(uid: d.id)) }
                }
            }
        } label: {
            Text(captures.label(audio.source)).font(.system(size: 11))
        }
        .controlSize(.small)
        .frame(width: 168)
        .onAppear { captures.refreshInputDevices() }
        .help("Where this scene listens. Rekordbox taps its output directly; no virtual audio driver needed.")
    }

    private func color(_ h: AudioCapture.Health) -> Color {
        switch h {
        case .running: return Theme.beatOn
        case .waiting, .silent: return Theme.accent
        case .error: return Theme.error
        case .off: return Theme.knobTrack
        }
    }
}

private struct SpectrumView: View {
    let bins: [Float]
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.1)))
            let n = bins.count
            let w = size.width / CGFloat(n)
            var path = Path()
            for (i, v) in bins.enumerated() {
                let h = CGFloat(v) * size.height
                path.addRect(CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(w - 0.5, 0.5), height: h))
            }
            ctx.fill(path, with: .color(Theme.modulation.opacity(0.85)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

private struct Meters: View {
    let meters: AudioMeters
    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            bar("bass", meters.bass)
            bar("mid", meters.mid)
            bar("high", meters.high)
            bar("lvl", meters.level)
            Spacer(minLength: 4)
            lamp("kick", meters.kick)
            lamp("snr", meters.snare)
            lamp("hat", meters.hat)
        }
        .frame(width: 168)
    }

    private func bar(_ name: String, _ v: Float) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1).fill(Color(white: 0.1))
                RoundedRectangle(cornerRadius: 1).fill(Theme.beatOn).frame(height: CGFloat(v) * 28)
            }
            .frame(width: 14, height: 28)
            Text(name).font(.system(size: 8)).foregroundStyle(Theme.textDim)
        }
        .help("audio.\(name == "lvl" ? "level" : name)")
    }

    private func lamp(_ name: String, _ v: Float) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(Theme.accent.opacity(Double(0.15 + 0.85 * v)))
                .frame(width: 12, height: 12)
                .frame(height: 28, alignment: .bottom)
            Text(name).font(.system(size: 8)).foregroundStyle(Theme.textDim)
        }
        .help("audio.\(name == "snr" ? "snare" : name)")
    }
}
