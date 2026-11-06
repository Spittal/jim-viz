import SwiftUI

/// A device's IO: its stream and trigger inputs, and its outputs. Shown as tags in columns
/// either side of the device's controls when its header's IO toggle is on: inputs on the left,
/// outputs on the right.
struct DeviceIO {
    let streamInputs: [StreamInput]
    let triggerInputs: [TriggerInput]
    let outputs: [OutputSignal]
    let streamOutputs: [StreamOutput]

    init(scene: RenderScene, key: String) {
        streamInputs = scene.streamInputs.filter { $0.deviceKey == key }
        triggerInputs = scene.triggerInputs.filter { $0.deviceKey == key }
        outputs = scene.outputs.filter { $0.deviceKey == key }
        streamOutputs = scene.streamOutputs.filter { $0.deviceKey == key }
    }

    var hasInputs: Bool { !streamInputs.isEmpty || !triggerInputs.isEmpty }
    var hasOutputs: Bool { !outputs.isEmpty || !streamOutputs.isEmpty }
    var isEmpty: Bool { !hasInputs && !hasOutputs }

    /// Whether an output of `kind` (one waiting to be mapped) can go into one of these inputs.
    func accepts(_ kind: IOKind) -> Bool {
        streamInputs.contains { kind.connects(to: $0.kind) } || (!triggerInputs.isEmpty && kind.connects(to: .trigger))
    }
}

/// A vertical, scrolling column of IO tags, at the device's fixed height. When the tags overflow,
/// they narrow to leave a gutter for the scrollbar, so it never covers them.
struct IOColumn<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    static var width: CGFloat { 180 }
    private static var padding: CGFloat { 6 }
    private static var scrollbarGutter: CGFloat { 12 }

    var body: some View {
        let overflows = contentHeight > viewportHeight + 0.5
        let tagWidth = Self.width - 2 * Self.padding - (overflows ? Self.scrollbarGutter : 0)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) { content }
                    .environment(\.ioTagWidth, tagWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { contentHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in contentHeight = h }
                    })
            }
            .scrollIndicators(.automatic)
            .background(GeometryReader { g in
                Color.clear.onAppear { viewportHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in viewportHeight = h }
            })
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct IOTagWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = IOColumn<EmptyView>.width - 12
}

extension EnvironmentValues {
    /// How wide IO tags draw: narrower while their column scrolls, to clear the scrollbar.
    var ioTagWidth: CGFloat {
        get { self[IOTagWidthKey.self] }
        set { self[IOTagWidthKey.self] = newValue }
    }
}

/// The pill every IO tag draws: icon, name, and what it's connected to.
private struct TagLabel<Icon: View>: View {
    @ViewBuilder let icon: Icon
    let name: String
    let detail: String?
    var connected = false
    @Environment(\.ioTagWidth) private var width

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(name).font(Theme.labelFont).foregroundStyle(Theme.text).lineLimit(1).layoutPriority(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(connected ? Theme.text.opacity(0.75) : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: 18, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
    }
}

private extension View {
    /// Menus drawn with a tag as their label.
    func tagMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    /// The outline a tag gets while it can take the output waiting to be mapped, or one dragged over it.
    func tagHighlight(_ on: Bool, hover: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.modulation, lineWidth: on || hover ? (hover ? 2 : 1) : 0))
    }
}

/// Toggles a mapping from a menu: adds it, or removes it if it's already there.
private func toggleMapping(_ engine: Engine, scene: RenderScene, source: String, target: String) {
    if let m = scene.mappings.first(where: { $0.source == source && $0.target == target }) {
        engine.removeMapping(m)
    } else {
        engine.addMapping(source: source, target: target)
    }
}

private func ticked(_ on: Bool, _ label: String) -> String { on ? "✓ \(label)" : label }

// MARK: - Inputs

/// A stream input, such as a generator's Background (video), Spectrum or Palette. Click it for
/// a menu of the outputs of its kind; it takes one. While an output of its kind is waiting to be
/// mapped, click it to map that, or drop one on it.
struct StreamInputTag: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    let input: StreamInput

    var body: some View {
        let source = scene.mappings.first { $0.target == input.key && $0.kind.isStream }
        let mapMode = engine.mapSource.map { engine.kind(of: $0) == input.kind } ?? false
        let candidates = scene.streamOutputs.filter { $0.kind == input.kind }
        let label = TagLabel(icon: {
            Image(systemName: input.kind.icon).font(.system(size: 9))
                .foregroundStyle(source?.isActive == true ? Theme.modulation : Theme.textDim)
        }, name: input.label, detail: source.map { $0.isActive ? $0.sourceLabel : "waiting" } ?? "None", connected: source != nil)
        Group {
            if mapMode {
                Button { engine.mapWaiting(to: input.key) } label: { label }.buttonStyle(.plain)
            } else {
                Menu {
                    Button(ticked(source == nil, "None")) { engine.setStreamInput(input.key, nil) }
                    if !candidates.isEmpty { Divider() }
                    ForEach(candidates) { v in
                        Button(ticked(source?.source == v.key, "\(v.device) · \(v.name)")) { engine.setStreamInput(input.key, v.key) }
                    }
                    if candidates.isEmpty {
                        switch input.kind {
                        case .spectrum: Text("Add Audio In to get a spectrum")
                        case .audio: Text("Add Audio In to get audio")
                        case .clock: Text("Add a Clock to get sync")
                        case .palette: Text("Add a Palette to get colours")
                        default: Text("Add a Webcam, Video or Picture to get video")
                        }
                    }
                } label: { label }
                .tagMenu()
            }
        }
        .tagHighlight(mapMode, hover: engine.dropKnob == input.key)
        .chainFrame(ChainDropDelegate.knobKey(input.key))
        .help("\(input.label): a \(input.kind.noun) input. Pick a \(input.kind.noun) output, or drop one here.")
    }
}

/// A trigger input, such as the Cutter's Cut or a Video's Jump. Click it for a menu to fire it
/// by hand or pick what fires it: trigger outputs on their event, value outputs each time they
/// rise past ½. It takes any number. While an output that can fire it is waiting to be mapped,
/// click it to map that (Shift-click to keep mapping), or drop one on it. It flashes when it fires.
struct TriggerInputTag: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    let input: TriggerInput

    var body: some View {
        let sources = scene.mappings.filter { $0.target == input.key }
        let waiting = engine.mapSource.flatMap { engine.kind(of: $0).connects(to: .trigger) ? $0 : nil }
        let detail = sources.isEmpty ? nil : sources.count > 1 ? "\(sources.count) mapped" : sources[0].isActive ? sources[0].sourceLabel : "waiting"
        let label = TagLabel(icon: { TriggerFlash(lastFired: { input.lastFired }, icon: true) },
                             name: input.label, detail: detail, connected: !sources.isEmpty)
        Group {
            if let waiting {
                Button { engine.mapWaiting(to: input.key, keepMapping: NSEvent.modifierFlags.contains(.shift)) } label: { label }
                    .buttonStyle(.plain)
                    .help("Click to map \(engine.sourceLabel(waiting)) onto \(input.label)")
            } else {
                Menu {
                    Button("Fire") { input.fire() }
                    Divider()
                    let triggers = scene.outputs.filter { $0.kind == .trigger }
                    if !triggers.isEmpty {
                        Section("Triggers") {
                            ForEach(triggers) { o in
                                Button(ticked(sources.contains { $0.source == o.key }, "\(o.device) · \(o.name)")) {
                                    toggleMapping(engine, scene: scene, source: o.key, target: input.key)
                                }
                            }
                        }
                    }
                    let values = scene.outputs.filter { $0.kind == .value }
                    let devices = values.reduce(into: [String]()) { if !$0.contains($1.device) { $0.append($1.device) } }
                    if !devices.isEmpty {
                        Section("Values (fire past ½)") {
                            ForEach(devices, id: \.self) { device in
                                Menu(device) {
                                    ForEach(values.filter { $0.device == device }) { o in
                                        Button(ticked(sources.contains { $0.source == o.key }, o.name)) {
                                            toggleMapping(engine, scene: scene, source: o.key, target: input.key)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: { label }
                .tagMenu()
                .help("\(input.label): a trigger input. Click to fire it or pick what fires it: a trigger, or a value that fires it when it rises past ½.")
            }
        }
        .tagHighlight(waiting != nil, hover: engine.dropKnob == input.key)
        .chainFrame(ChainDropDelegate.knobKey(input.key))
    }
}

// MARK: - Outputs

/// A value or trigger output. Click it for a menu of where it can go: knobs by device (values
/// only) and trigger inputs, ticked where it's mapped. "Map by Clicking" waits for a click on a
/// knob or input instead.
struct OutputTag: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    let output: OutputSignal

    var body: some View {
        let mapped = scene.mappings.filter { $0.source == output.key }
        let mapping = engine.mapSource == output.key
        let label = TagLabel(icon: {
            if output.kind == .trigger {
                TriggerFlash(lastFired: { output.lastFired }, icon: true)
            } else {
                Image(systemName: output.kind.icon).font(.system(size: 9))
                    .foregroundStyle(mapped.isEmpty ? Theme.textDim : Theme.modulation)
            }
        }, name: output.name, detail: summary(mapped), connected: !mapped.isEmpty)
        Group {
            if mapping {
                Button { engine.mapSource = nil } label: { label }.buttonStyle(.plain)
                    .help("Click a \(output.kind == .trigger ? "trigger input" : "knob") to map \(output.name). Click here to cancel.")
            } else {
                Menu {
                    Button("Map by Clicking…") { engine.mapSource = output.key }
                    Divider()
                    if !scene.triggerInputs.isEmpty {
                        Section("Triggers") {
                            ForEach(scene.triggerInputs) { t in
                                Button(ticked(mapped.contains { $0.target == t.key }, engine.targetLabel(t.key))) {
                                    toggleMapping(engine, scene: scene, source: output.key, target: t.key)
                                }
                            }
                        }
                    } else if output.kind == .trigger {
                        Text("Nothing in the scene takes triggers")
                    }
                    if output.kind == .value {
                        Section("Knobs") {
                            ForEach(scene.deviceKeys, id: \.self) { path in
                                if let bank = scene.banksByPath[path], !bank.params.isEmpty {
                                    Menu(engine.deviceName(path)) {
                                        ForEach(bank.params) { p in
                                            let target = "\(path).\(p.def.name)"
                                            Button(ticked(mapped.contains { $0.target == target }, knobLabel(p.def.name))) {
                                                toggleMapping(engine, scene: scene, source: output.key, target: target)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: { label }
                .tagMenu()
                .help("\(output.device) · \(output.name). Click to pick where it goes.")
            }
        }
        .tagHighlight(mapping, hover: false)
    }

    private func summary(_ mapped: [MappingRuntime]) -> String? {
        switch mapped.count {
        case 0: return nil
        case 1: return "→ \(mapped[0].targetLabel)"
        default: return "→ \(mapped.count)"
        }
    }
}

/// A stream output (video, spectrum, palette, audio, clock sync). Click it for a menu of the
/// inputs of its kind, ticked where it's mapped.
struct StreamOutputTag: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    let stream: StreamOutput

    var body: some View {
        let mapped = scene.mappings.filter { $0.source == stream.key }
        let mapping = engine.mapSource == stream.key
        let targets = scene.streamInputs.filter { $0.kind == stream.kind }
        let noun = stream.kind.noun
        let label = TagLabel(icon: {
            Image(systemName: stream.kind.icon).font(.system(size: 9))
                .foregroundStyle(mapped.isEmpty ? Theme.textDim : Theme.modulation)
        }, name: stream.name, detail: mapped.isEmpty ? nil : mapped.count == 1 ? "→ \(mapped[0].targetLabel)" : "→ \(mapped.count)",
           connected: !mapped.isEmpty)
        Group {
            if mapping {
                Button { engine.mapSource = nil } label: { label }.buttonStyle(.plain)
                    .help("Click a \(noun) input to map \(stream.name). Click here to cancel.")
            } else {
                Menu {
                    Button("Map by Clicking…") { engine.mapSource = stream.key }
                    Divider()
                    ForEach(targets) { input in
                        let done = mapped.contains { $0.target == input.key }
                        Button(ticked(done, engine.targetLabel(input.key))) {
                            if done { engine.setStreamInput(input.key, nil) } else { engine.setStreamInput(input.key, stream.key) }
                        }
                    }
                    if targets.isEmpty { Text("Nothing in the scene takes \(noun)") }
                } label: { label }
                .tagMenu()
                .help("\(stream.device) · \(stream.name): \(noun). Click to pick which inputs it feeds.")
            }
        }
        .tagHighlight(mapping, hover: false)
    }
}
