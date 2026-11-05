import SwiftUI

/// An LFO, in the Modulation section. Its output (in the inspector) drives other knobs, and its
/// own knobs can be mapped, so LFOs can modulate each other.
struct LFODevice: View {
    @Environment(Engine.self) private var engine
    @Bindable var mod: ModulatorRuntime

    var body: some View {
        DevicePanel(title: mod.id, subtitle: mod.presetLabel ?? Tools.label(.modulation, mod.type), isOn: $mod.enabled,
                    select: "mod.\(mod.id)", onClose: { engine.removeModulator(id: mod.id) }) {
            HStack(alignment: .top, spacing: 6) {
                WaveScope(mod: mod).frame(width: 96, height: 44)
                KnobGrid(params: mod.bank.params, prefix: "mod.\(mod.id)")
            }
        }
    }
}

/// The LFO's current shape over two cycles, with a line at its live output.
private struct WaveScope: View {
    let mod: ModulatorRuntime

    var body: some View {
        let shape = Int((mod.bank["shape"]?.display ?? 0).rounded())
        let depth = mod.bank["depth"]?.display ?? 1
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.1)))
                var path = Path()
                let n = 96
                for i in 0...n {
                    let x = Double(i) / Double(n) * 2
                    // Fixed seed so random shapes don't flicker.
                    let y = CGFloat(Wave.lfo(shape: shape, x + 0.37) * depth)
                    let p = CGPoint(x: CGFloat(i) / CGFloat(n) * size.width, y: (1 - y) * (size.height - 4) + 2)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                ctx.stroke(path, with: .color(Theme.modulation.opacity(0.8)), lineWidth: 1.2)
                let v = CGFloat(mod.output.value)
                let y = (1 - v) * (size.height - 4) + 2
                ctx.fill(Path(CGRect(x: 0, y: y - 0.5, width: size.width, height: 1)), with: .color(Theme.accent.opacity(0.7)))
                ctx.fill(Path(ellipseIn: CGRect(x: size.width - 6, y: y - 3, width: 6, height: 6)), with: .color(Theme.accent))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .opacity(mod.enabled ? 1 : 0.4)
    }
}

/// One output: name, live meter, map button. The whole row is a drag source for knobs.
struct OutputRow: View {
    @Environment(Engine.self) private var engine
    let output: OutputSignal
    var compact = false

    var body: some View {
        let mapping = engine.mapSource == output.key
        HStack(spacing: 5) {
            Text(output.name)
                .font(compact ? .system(size: 9) : .system(size: 11))
                .foregroundStyle(mapping ? Theme.modulation : Theme.text)
                .lineLimit(1)
                .frame(width: compact ? 66 : 82, alignment: .leading)
            LiveMeter(output: output)
                .frame(height: compact ? 4 : 6)
            Button { engine.mapSource = mapping ? nil : output.key } label: {
                Image(systemName: mapping ? "scope" : "plus.circle")
                    .font(.system(size: compact ? 9 : 11, weight: mapping ? .bold : .regular))
            }
            .buttonStyle(.plain)
            .foregroundStyle(mapping ? Theme.modulation : Theme.textDim)
            .help(mapping ? "Click a knob to map \(output.name) to it (Shift-click to map several). Click here to cancel."
                          : "Map \(output.name): click this, then click a knob")
        }
        .padding(.vertical, compact ? 0 : 2)
        .padding(.horizontal, mapping && !compact ? 4 : 0)
        .background(RoundedRectangle(cornerRadius: 3).fill(mapping && !compact ? Theme.modulation.opacity(0.15) : .clear))
        .contentShape(Rectangle())
        .chainDragSource(.output(output.key), engine: engine)
        .help("\(output.device) · \(output.name). Drag onto a knob to map it.")
    }
}

/// A horizontal bar showing a live 0...1 value, redrawn at 30 fps while visible.
/// Values are read from render-thread fields that SwiftUI doesn't observe, so the value is
/// read in the timeline's closure each tick and passed down: a read inside a GeometryReader
/// would only happen on layout, leaving the bar frozen.
struct LiveMeter: View {
    var color: Color = Theme.modulation
    let value: () -> Float

    init(color: Color = Theme.modulation, value: @escaping () -> Float) {
        self.color = color; self.value = value
    }

    init(output: OutputSignal) { self.init { output.value } }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            MeterBar(value: CGFloat(min(max(value(), 0), 1)), color: color)
        }
    }
}

private struct MeterBar: View {
    let value: CGFloat
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 1), with: .color(Color(white: 0.1)))
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width * value, height: size.height), cornerRadius: 1),
                     with: .color(color))
        }
    }
}

/// A MIDI controller (or every connected one). Learned controls become its outputs, which
/// the inspector lists and maps like any other output.
struct MIDIInputDevice: View {
    @Environment(Engine.self) private var engine
    let input: MIDIInputRuntime

    var body: some View {
        let learning = engine.learningMIDI == input.key
        let connected = input.device.map { name in engine.midi.devices.contains { $0.name == name } } ?? !engine.midi.devices.isEmpty
        DevicePanel(title: "MIDI Input", subtitle: input.title, statusColor: connected ? Theme.beatOn : Theme.knobTrack,
                    select: input.key, onClose: { engine.removeInput(input.key) }) {
            VStack(alignment: .leading, spacing: 7) {
                Menu {
                    Button("All Devices") { engine.setMIDIDevice(input.key, nil) }
                    Divider()
                    ForEach(engine.midi.devices) { d in
                        Button(d.name) { engine.setMIDIDevice(input.key, d.name) }
                    }
                } label: {
                    Text(input.title).font(.system(size: 11))
                }
                .controlSize(.small)
                .help(connected ? "Which controller to listen to" : "Not connected. Plug it in, or pick another device.")
                Toggle(isOn: Binding(get: { learning }, set: { engine.learningMIDI = $0 ? input.key : nil })) {
                    Label(learning ? "Learning…" : "Learn Controls", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
                .tint(Theme.midi)
                .controlSize(.small)
                .help("While on, each new control you move becomes an output you can map")
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    let recent = CFAbsoluteTimeGetCurrent() - input.lastActivity < 0.2
                    HStack(spacing: 5) {
                        Circle().fill(recent ? Theme.midi : Theme.knobTrack).frame(width: 7, height: 7)
                        Text(input.lastControl?.label ?? "No MIDI yet")
                            .font(Theme.labelFont)
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                    }
                }
                Text("\(input.controls.count) control\(input.controls.count == 1 ? "" : "s") learned")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(width: 150, alignment: .leading)
        }
        .onAppear { engine.midi.refreshEndpoints() }
    }
}

/// A Webcam input: a live preview of its processed video, the camera picker and its
/// processing knobs. Its video goes to the generator's Video In; motion and brightness are
/// value outputs, in the inspector.
struct WebcamDevice: View {
    @Environment(Engine.self) private var engine
    let webcam: WebcamRuntime

    var body: some View {
        let feed = webcam.feed
        DevicePanel(title: "Webcam", subtitle: webcam.device ?? "Default camera", statusColor: color(feed.status),
                    select: webcam.key, onClose: { engine.removeInput(webcam.key) }) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    VideoPreviewView(texture: webcam.processed)
                        .frame(width: 160, height: 90)
                        .overlay {
                            if feed.status != .running {
                                Text(statusText(feed.status))
                                    .font(Theme.labelFont)
                                    .foregroundStyle(Theme.textDim)
                                    .multilineTextAlignment(.center)
                                    .padding(6)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    Menu {
                        Button("Default Camera") { engine.setWebcamDevice(webcam.key, nil) }
                        Divider()
                        ForEach(engine.webcams.devices) { d in
                            Button(d.name) { engine.setWebcamDevice(webcam.key, d.name) }
                        }
                    } label: {
                        Text(feed.activeName ?? webcam.device ?? "Default camera").font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .frame(width: 160)
                    .help("Which camera to use")
                    let routes = engine.current?.mappings.filter { $0.source == webcam.video.key && $0.isActive } ?? []
                    Text(routes.isEmpty ? "Video not mapped" : "Video → " + routes.map(\.targetLabel).joined(separator: ", "))
                        .font(Theme.labelFont)
                        .foregroundStyle(routes.isEmpty ? Theme.textDim : Theme.modulation)
                        .lineLimit(2)
                    DepthPreview(webcam: webcam)
                }
                .frame(width: 160)
                KnobGrid(params: webcam.bank.params, prefix: webcam.key)
            }
        }
    }

    private func statusText(_ s: WebcamFeed.Status) -> String {
        switch s {
        case .off, .starting: return "Starting camera…"
        case .running: return ""
        case .notFound: return "Camera not connected"
        case .denied: return "No camera access. Allow jim-viz in System Settings › Privacy & Security › Camera."
        case .failed(let why): return why
        }
    }

    private func color(_ s: WebcamFeed.Status) -> Color {
        switch s {
        case .running: return Theme.beatOn
        case .starting, .off: return Theme.accent
        case .notFound, .denied, .failed: return Theme.error
        }
    }
}

/// A webcam's Depth output: its route, and while it's mapped a live preview with the depth
/// model's state (loading, missing, rate).
private struct DepthPreview: View {
    @Environment(Engine.self) private var engine
    let webcam: WebcamRuntime

    var body: some View {
        let routes = engine.current?.mappings.filter { $0.source == webcam.depthVideo.key && $0.isActive } ?? []
        VStack(alignment: .leading, spacing: 6) {
            if webcam.depthMapped {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let depth = webcam.feed.depth
                    VideoPreviewView(texture: webcam.depth)
                        .frame(width: 160, height: 90)
                        .overlay {
                            if let text = statusText(depth.status) {
                                Text(text)
                                    .font(Theme.labelFont)
                                    .foregroundStyle(Theme.textDim)
                                    .multilineTextAlignment(.center)
                                    .padding(6)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if depth.status == .running {
                                Text("\(Int(depth.framesPerSecond.rounded())) fps · \(Int(depth.milliseconds.rounded())) ms")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.textDim)
                                    .padding(3)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
            Text(routes.isEmpty ? "Depth not mapped" : "Depth → " + routes.map(\.targetLabel).joined(separator: ", "))
                .font(Theme.labelFont)
                .foregroundStyle(routes.isEmpty ? Theme.textDim : Theme.modulation)
                .lineLimit(2)
                .help("Depth estimated from the image, white = near. Map it into a generator's Depth input.")
        }
    }

    private func statusText(_ s: DepthEstimator.Status) -> String? {
        if webcam.feed.status != .running { return nil }
        switch s {
        case .idle, .loading: return "Loading depth model…"
        case .running: return nil
        case .missingModel: return "Depth model not installed. Run scripts/fetch-depth-model.sh"
        case .failed(let why): return why
        }
    }
}

/// Shows a video texture (a webcam's processed video or depth), drawn by the render loop.
private struct VideoPreviewView: NSViewRepresentable {
    @Environment(Engine.self) private var engine
    let texture: MTLTexture

    func makeNSView(context: Context) -> MetalSurfaceView {
        let texture = texture
        return MetalSurfaceView(device: engine.device, loop: engine.loop) { texture }
    }

    func updateNSView(_ nsView: MetalSurfaceView, context: Context) {}
}

/// A stream input socket, such as the generator's Background (video), Spectrum or Palette.
/// Pick an output of its kind from its menu, click it while one is waiting to be mapped, or
/// drop one on it.
struct StreamSocket: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    let input: StreamInput

    var body: some View {
        let source = scene.mappings.first { $0.target == input.key && $0.kind.isStream }
        let mapMode = engine.mapSource.map { engine.kind(of: $0) == input.kind } ?? false
        let candidates = scene.streamOutputs.filter { $0.kind == input.kind }
        let hover = engine.dropKnob == input.key
        let highlight = mapMode || hover
        Group {
            if mapMode, let waiting = engine.mapSource {
                Button { engine.addMapping(source: waiting, target: input.key); engine.mapSource = nil } label: { chip(source) }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    Button("None") { engine.setStreamInput(input.key, nil) }
                    if !candidates.isEmpty { Divider() }
                    ForEach(candidates) { v in
                        Button("\(v.device) · \(v.name)") { engine.setStreamInput(input.key, v.key) }
                    }
                    if candidates.isEmpty { Text(input.kind == .spectrum ? "Add Audio In to get a spectrum" : "Add a Webcam input to get video") }
                } label: { chip(source) }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.modulation, lineWidth: highlight ? (hover ? 2 : 1) : 0))
        .chainFrame(ChainDropDelegate.knobKey(input.key))
        .help("\(input.label): a \(input.kind.noun) input. Pick a \(input.kind.noun) output, or drop one here.")
    }

    private func chip(_ source: MappingRuntime?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: input.kind.icon).font(.system(size: 9))
                .foregroundStyle(source?.isActive == true ? Theme.modulation : Theme.textDim)
            Text(input.label).font(Theme.labelFont).foregroundStyle(Theme.textDim)
            Text(source.map { $0.isActive ? $0.sourceLabel : "waiting" } ?? "None")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(source == nil ? Theme.textDim : Theme.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
    }
}
