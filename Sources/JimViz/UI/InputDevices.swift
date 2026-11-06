import SwiftUI

/// An LFO, in the Modulation section. Its output (in the inspector) drives other knobs, and its
/// own knobs can be mapped, so LFOs can modulate each other. It syncs to clock only when
/// mapped from Clock (Clock · Sync → mod.<id>.sync); otherwise it runs free.
struct LFODevice: View {
    @Environment(Engine.self) private var engine
    @Bindable var mod: ModulatorRuntime
    var accent: Color? = nil

    var body: some View {
        let isSyncWaiting = engine.mapSource.map { engine.kind(of: $0) == .clock } ?? false
        let subtitle = mod.presetLabel.map { "\($0) · \(mod.isSynced ? "Sync" : "Free")" } ?? (mod.isSynced ? "Sync" : "Free")
        DevicePanel(title: mod.id, subtitle: subtitle, isOn: $mod.enabled,
                    accent: accent,
                    select: "mod.\(mod.id)", onClose: { engine.removeModulator(id: mod.id) }) {
            VStack(alignment: .leading, spacing: 6) {
                if let scene = engine.current {
                    HStack(spacing: 4) {
                        if let reset = mod.resetTrigger { TriggerPad(scene: scene, input: reset) }
                        if let socket = scene.streamInputs.first(where: { $0.key == "mod.\(mod.id).sync" }), isSyncWaiting || mod.isSynced {
                            StreamSocket(scene: scene, input: socket)
                        }
                        Spacer()
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    WaveScope(mod: mod).frame(width: 96, height: 58)
                    let visibleParams = mod.bank.params.filter { p in
                        mod.isSynced ? p.def.name != "hz" : p.def.name != "rate"
                    }
                    KnobGrid(params: visibleParams, prefix: "mod.\(mod.id)")
                }
            }
        }
    }
}

/// A modulator in the Modulation section: an LFO or a Math.
struct ModulatorDevice: View {
    let mod: ModulatorRuntime
    var accent: Color? = nil

    var body: some View {
        switch mod.type {
        case .lfo: LFODevice(mod: mod, accent: accent)
        case .math: MathDevice(mod: mod, accent: accent)
        }
    }
}

/// A Math, in the Modulation section. Map an output onto its `a` knob; its Out (in the
/// inspector) is `op(a, b)`. `b` is a knob too, so mapping a second output there combines two.
struct MathDevice: View {
    @Environment(Engine.self) private var engine
    @Bindable var mod: ModulatorRuntime
    var accent: Color? = nil

    var body: some View {
        DevicePanel(title: mod.id, subtitle: mod.presetLabel, isOn: $mod.enabled, accent: accent,
                    select: "mod.\(mod.id)", onClose: { engine.removeModulator(id: mod.id) }) {
            HStack(alignment: .top, spacing: 6) {
                MathScope(mod: mod).frame(width: 58, height: 58)
                KnobGrid(params: mod.bank.params, prefix: "mod.\(mod.id)")
            }
        }
    }
}

/// The Math's transfer curve (out against a, at the current b and op), with a dot at the live
/// input and output.
private struct MathScope: View {
    let mod: ModulatorRuntime

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { ctx, size in
                let w = size.width, h = size.height, inset: CGFloat = 4
                func pt(_ x: Float, _ y: Float) -> CGPoint {
                    CGPoint(x: inset + CGFloat(x) * (w - inset * 2), y: h - inset - CGFloat(min(max(y, 0), 1)) * (h - inset * 2))
                }
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.1)))
                var diag = Path()
                diag.move(to: pt(0, 0)); diag.addLine(to: pt(1, 1))
                ctx.stroke(diag, with: .color(Color.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

                let op = Int((mod.bank["op"]?.display ?? 0).rounded())
                let b = mod.bank["b"]?.display ?? 0.5
                let a = mod.bank["a"]?.display ?? 0
                let n = 96
                var curve = Path()
                for i in 0...n {
                    let x = Float(i) / Float(n)
                    let p = pt(x, MathParams.apply(op: op, x, b))
                    if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                }
                ctx.stroke(curve, with: .color(Theme.modulation.opacity(0.75)), lineWidth: 1.2)

                let dot = pt(a, mod.output.value)
                ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)), with: .color(Theme.accent.opacity(0.35)))
                ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 2.5, y: dot.y - 2.5, width: 5, height: 5)), with: .color(Theme.accent))
            }
            .overlay(alignment: .bottomTrailing) {
                Text(String(format: "%.2f", mod.output.value))
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
                    .padding(3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .opacity(mod.enabled ? 1 : 0.4)
    }
}

/// The LFO's current shape and live output, animated in real time.
private struct WaveScope: View {
    let mod: ModulatorRuntime

    var body: some View {
        let shape = Int((mod.bank["shape"]?.display ?? 0).rounded())
        let depth = CGFloat(mod.bank["depth"]?.display ?? 1)
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let midY = h / 2

                // Background
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.1)))

                // Center zero line for bipolar display
                var centerLine = Path()
                centerLine.move(to: CGPoint(x: 0, y: midY))
                centerLine.addLine(to: CGPoint(x: w, y: midY))
                ctx.stroke(centerLine, with: .color(Color.white.opacity(0.15)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

                let v = CGFloat(mod.output.value)
                let phase = Double(mod.currentPhase)

                // Animated waveform: draws 1.5 cycles, scrolling smoothly with the LFO's phase
                let n = 96
                var wavePath = Path()
                for i in 0...n {
                    let progress = Double(i) / Double(n) * 1.5
                    let cycle = progress + phase
                    let val = CGFloat(Wave.lfo(shape: shape, cycle)) * depth
                    let y = midY - val * (midY - 4)
                    let p = CGPoint(x: CGFloat(i) / CGFloat(n) * w, y: y)
                    if i == 0 { wavePath.move(to: p) } else { wavePath.addLine(to: p) }
                }
                ctx.stroke(wavePath, with: .color(Theme.modulation.opacity(0.75)), lineWidth: 1.2)

                // Current output level indicator: horizontal dashed line
                let liveY = midY - v * (midY - 4)
                var levelLine = Path()
                levelLine.move(to: CGPoint(x: 0, y: liveY))
                levelLine.addLine(to: CGPoint(x: w, y: liveY))
                ctx.stroke(levelLine, with: .color(Theme.accent.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                // Glowing cursor at current value on the right edge
                let dotX = w - 6
                let halo = CGRect(x: dotX - 4, y: liveY - 4, width: 8, height: 8)
                let dot = CGRect(x: dotX - 2.5, y: liveY - 2.5, width: 5, height: 5)
                ctx.fill(Path(ellipseIn: halo), with: .color(Theme.accent.opacity(0.35)))
                ctx.fill(Path(ellipseIn: dot), with: .color(Theme.accent))
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    Text(mod.isSynced ? "SYNC" : "FREE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(mod.isSynced ? Theme.accent : Theme.textDim)
                    Text(String(format: "%+.2f", mod.output.value))
                        .font(.system(size: 8, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textDim)
                }
                .padding(3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.08), lineWidth: 1))
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
            if output.kind == .trigger {
                TriggerFlash(lastFired: { output.lastFired })
                    .frame(height: compact ? 4 : 6)
            } else {
                LiveMeter(output: output)
                    .frame(height: compact ? 4 : 6)
            }
            Button { engine.mapSource = mapping ? nil : output.key } label: {
                Image(systemName: mapping ? "scope" : "plus.circle")
                    .font(.system(size: compact ? 9 : 11, weight: mapping ? .bold : .regular))
            }
            .buttonStyle(.plain)
            .foregroundStyle(mapping ? Theme.modulation : Theme.textDim)
            .help(output.kind == .trigger
                  ? (mapping ? "Click a trigger input to map \(output.name) to it. Click here to cancel."
                             : "Map \(output.name): click this, then a trigger input")
                  : (mapping ? "Click a knob to map \(output.name) to it (Shift-click to map several). Click here to cancel."
                             : "Map \(output.name): click this, then click a knob"))
        }
        .padding(.vertical, compact ? 0 : 2)
        .padding(.horizontal, mapping && !compact ? 4 : 0)
        .background(RoundedRectangle(cornerRadius: 3).fill(mapping && !compact ? Theme.modulation.opacity(0.15) : .clear))
        .contentShape(Rectangle())
        .chainDragSource(.output(output.key), engine: engine)
        .help(output.kind == .trigger ? "\(output.device) · \(output.name), a trigger. Drag onto a trigger input to map it."
                                      : "\(output.device) · \(output.name). Drag onto a knob or a trigger input to map it.")
    }
}

/// A horizontal bar showing a live value (0...1 for unipolar, -1...1 for bipolar), redrawn at 30 fps while visible.
/// Values are read from render-thread fields that SwiftUI doesn't observe, so the value is
/// read in the timeline's closure each tick and passed down: a read inside a GeometryReader
/// would only happen on layout, leaving the bar frozen.
struct LiveMeter: View {
    var color: Color = Theme.modulation
    var isBipolar: Bool = false
    let value: () -> Float

    init(color: Color = Theme.modulation, isBipolar: Bool = false, value: @escaping () -> Float) {
        self.color = color; self.isBipolar = isBipolar; self.value = value
    }

    init(output: OutputSignal) { self.init(isBipolar: output.isBipolar) { output.value } }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let v = CGFloat(isBipolar ? min(max(value(), -1), 1) : min(max(value(), 0), 1))
            MeterBar(value: v, color: color, isBipolar: isBipolar)
        }
    }
}

private struct MeterBar: View {
    let value: CGFloat
    let color: Color
    var isBipolar: Bool = false

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 1), with: .color(Color(white: 0.1)))
            if isBipolar {
                let mid = size.width / 2
                let w = value * mid
                ctx.fill(Path(CGRect(x: min(mid, mid + w), y: 0, width: max(1, abs(w)), height: size.height)),
                         with: .color(color))
                ctx.fill(Path(CGRect(x: mid - 0.5, y: 0, width: 1, height: size.height)), with: .color(Color.white.opacity(0.35)))
            } else {
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width * value, height: size.height), cornerRadius: 1),
                         with: .color(color))
            }
        }
    }
}

/// A MIDI controller (or every connected one). Learned controls become its outputs, which
/// the inspector lists and maps like any other output.
struct MIDIInputDevice: View {
    @Environment(Engine.self) private var engine
    let input: MIDIInputRuntime
    var accent: Color? = nil

    var body: some View {
        let learning = input.isLearning
        let connected = input.device.map { name in engine.midi.devices.contains { $0.name == name } } ?? !engine.midi.devices.isEmpty
        DevicePanel(title: "MIDI Input", subtitle: input.title, statusColor: connected ? Theme.beatOn : Theme.knobTrack,
                    accent: accent,
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
                Toggle(isOn: Binding(get: { learning }, set: { on in
                    engine.current?.learnMIDI(on ? input.key : nil)
                    if on { engine.selectDevice(input.key); engine.showInspector = true }
                })) {
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
    var accent: Color? = nil

    var body: some View {
        let feed = webcam.feed
        DevicePanel(title: "Webcam", subtitle: webcam.device ?? "Default camera", statusColor: color(feed.status),
                    accent: accent,
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
                    DepthPreview(source: webcam)
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

/// While a video source's Depth output is mapped, a live preview with the depth model's state
/// (loading, missing, rate). Its routes show in the inspector.
private struct DepthPreview: View {
    @Environment(Engine.self) private var engine
    let source: any VideoSourceRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if source.depthMapped {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let depth = source.sourceFeed.depth
                    VideoPreviewView(texture: source.depth)
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
        }
    }

    private func statusText(_ s: DepthEstimator.Status) -> String? {
        switch s {
        case .idle, .loading: return "Loading depth model…"
        case .running: return nil
        case .missingModel: return "Depth model not installed. Run scripts/fetch-depth-model.sh"
        case .failed(let why): return why
        }
    }
}

struct VideoDevice: View {
    @Environment(Engine.self) private var engine
    let video: VideoRuntime
    var accent: Color? = nil

    var body: some View {
        let feed = video.feed
        DevicePanel(title: "Video", subtitle: video.displayName, statusColor: color(feed.status),
                    accent: accent,
                    select: video.key, onClose: { engine.removeInput(video.key) }) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    VideoPreviewView(texture: video.processed)
                        .frame(width: 160, height: 90)
                        .overlay {
                            if feed.status != .playing {
                                Text(statusText(feed.status))
                                    .font(Theme.labelFont)
                                    .foregroundStyle(Theme.textDim)
                                    .multilineTextAlignment(.center)
                                    .padding(6)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    Menu {
                        let files = engine.store.availableVideos()
                        if !files.isEmpty {
                            ForEach(files, id: \.self) { f in
                                Button(f) { engine.setVideoFile(video.key, f) }
                            }
                            Divider()
                        }
                        Button("Choose File…") { chooseFile() }
                    } label: {
                        Text(video.displayName).font(.system(size: 11)).lineLimit(1)
                    }
                    .controlSize(.small)
                    .frame(width: 160)
                    .help("Which video file to loop")
                    VideoTransportBar(video: video).frame(width: 160, height: 8)
                    if let scene = engine.current {
                        HStack(spacing: 4) { TriggerPad(scene: scene, input: video.jumpTrigger); Spacer(minLength: 0) }
                    }
                    DepthPreview(source: video)
                }
                .frame(width: 160)
                KnobGrid(params: video.bank.params, prefix: video.key)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        if panel.runModal() == .OK, let url = panel.url {
            engine.setVideoFile(video.key, url.path)
        }
    }

    private func statusText(_ s: VideoFeed.Status) -> String {
        switch s {
        case .off: return "Video stopped"
        case .loading: return "Loading video…"
        case .playing: return ""
        case .notFound: return "No video file selected"
        case .failed(let why): return why
        }
    }

    private func color(_ s: VideoFeed.Status) -> Color {
        switch s {
        case .playing: return Theme.beatOn
        case .loading, .off: return Theme.accent
        case .notFound, .failed: return Theme.error
        }
    }
}

struct PictureDevice: View {
    @Environment(Engine.self) private var engine
    let picture: PictureRuntime
    var accent: Color? = nil

    var body: some View {
        let feed = picture.feed
        DevicePanel(title: "Picture", subtitle: picture.displayName, statusColor: color(feed.status),
                    accent: accent,
                    select: picture.key, onClose: { engine.removeInput(picture.key) }) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    VideoPreviewView(texture: picture.processed)
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
                        let files = engine.store.availablePictures()
                        if !files.isEmpty {
                            ForEach(files, id: \.self) { f in
                                Button(f) { engine.setPictureFile(picture.key, f) }
                            }
                            Divider()
                        }
                        Button("Choose File…") { chooseFile() }
                    } label: {
                        Text(picture.displayName).font(.system(size: 11)).lineLimit(1)
                    }
                    .controlSize(.small)
                    .frame(width: 160)
                    .help("Which image file to display")
                    DepthPreview(source: picture)
                }
                .frame(width: 160)
                KnobGrid(params: picture.bank.params, prefix: picture.key)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            engine.setPictureFile(picture.key, url.path)
        }
    }

    private func statusText(_ s: PictureFeed.Status) -> String {
        switch s {
        case .off: return "Picture off"
        case .loading: return "Loading image…"
        case .running: return ""
        case .notFound: return "No image file selected"
        case .failed(let why): return why
        }
    }

    private func color(_ s: PictureFeed.Status) -> Color {
        switch s {
        case .running: return Theme.beatOn
        case .loading, .off: return Theme.accent
        case .notFound, .failed: return Theme.error
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
                    if candidates.isEmpty {
                        switch input.kind {
                        case .spectrum: Text("Add Audio In to get a spectrum")
                        case .audio: Text("Add Audio In to get audio")
                        default: Text("Add a Webcam input to get video")
                        }
                    }
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

/// A trigger input's pad, such as the Cutter's Cut or a Video's Jump. Click it to fire it by
/// hand. While an output that can fire it is waiting to be mapped (a trigger, or a value, which
/// fires it when it rises past ½), click it to map that output (Shift-click to keep mapping),
/// or drop one on it. It flashes each time it fires, and names what's mapped into it.
struct TriggerPad: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    let input: TriggerInput

    var body: some View {
        let sources = scene.mappings.filter { $0.target == input.key }
        let waiting = engine.mapSource.flatMap { engine.kind(of: $0).connects(to: .trigger) ? $0 : nil }
        let hover = engine.dropKnob == input.key
        Button {
            if let waiting {
                engine.addMapping(source: waiting, target: input.key)
                if !NSEvent.modifierFlags.contains(.shift) { engine.mapSource = nil }
            } else {
                input.fire()
            }
        } label: {
            HStack(spacing: 4) {
                TriggerFlash(lastFired: { input.lastFired }, icon: true)
                Text(input.label).font(Theme.labelFont).foregroundStyle(Theme.text)
                if !sources.isEmpty {
                    Text(sources.count > 1 ? "\(sources.count) mapped" : sources[0].isActive ? sources[0].sourceLabel : "waiting")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.modulation, lineWidth: waiting != nil || hover ? (hover ? 2 : 1) : 0))
        .chainFrame(ChainDropDelegate.knobKey(input.key))
        .help(waiting != nil ? "Click to map \(engine.sourceLabel(waiting!)) onto \(input.label)"
                             : "\(input.label): a trigger input. Click to fire it. Map a trigger, or a value that fires it when it rises past ½ (an LFO, a kick, a MIDI pad).")
    }
}

/// Lights up for a moment each time something fires: a trigger output's meter, or a pad's bolt.
struct TriggerFlash: View {
    let lastFired: () -> CFTimeInterval
    var icon = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let flash = max(0, 1 - (CACurrentMediaTime() - lastFired()) / 0.25)
            if icon {
                Image(systemName: "bolt.fill").font(.system(size: 9))
                    .foregroundStyle(flash > 0 ? Theme.modulation.opacity(0.4 + 0.6 * flash) : Theme.textDim)
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(flash > 0 ? Theme.modulation.opacity(0.25 + 0.75 * flash) : Color(white: 0.1))
            }
        }
    }
}

/// A Video's transport: the span between its in and out points, and where playback is.
struct VideoTransportBar: View {
    let video: VideoRuntime

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let a = CGFloat(video.bank["inPoint"]?.display ?? 0), b = CGFloat(video.bank["outPoint"]?.display ?? 1)
            let head = CGFloat(min(max(video.feed.position, 0), 1))
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(Color(white: 0.1)))
                let lo = min(a, b) * size.width, hi = max(a, b) * size.width
                ctx.fill(Path(CGRect(x: lo, y: 0, width: max(hi - lo, 1), height: size.height)), with: .color(Theme.modulation.opacity(0.3)))
                ctx.fill(Path(CGRect(x: head * size.width - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.text))
            }
        }
        .help("In and out points (the lit span) and the playhead. Set them with the in point and out point knobs.")
    }
}
