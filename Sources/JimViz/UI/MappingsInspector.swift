import SwiftUI

/// The right-hand inspector, showing the device selected in the chain: its outputs, where each
/// one is mapped (with the mapping's settings), and what is mapped into its knobs. With nothing
/// selected it lists every mapping in the scene.
///
/// Map an output by clicking its + and then a knob (Shift-click maps several), from its
/// → menu, or by dragging it onto a knob. MIDI controllers are MIDI Input devices whose
/// learned controls are outputs like any other. Mappings belong to the scene and save with it (⌘S).
struct MappingsInspector: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let scene = engine.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        hint
                        if let key = engine.selectedDevice, scene.deviceKeys.contains(key) {
                            DeviceInspector(scene: scene, key: key)
                        } else {
                            Text("Select a device in the chain to see its outputs and map them.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10).padding(.top, 12)
                            InspectorSection("All Mappings", key: "all") {
                                if scene.mappings.isEmpty {
                                    empty("No mappings in this scene yet.")
                                }
                                ForEach(scene.mappings) { MappingRow(mapping: $0) }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            } else {
                Text("No scene loaded").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Mappings").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                if let key = engine.selectedDevice, let scene = engine.current {
                    let list = scene.mappings.filter { devicePath($0.source) == key || devicePath($0.target) == key }
                    Button("Copy \(engine.deviceName(key)) Mappings") { engine.copyMappings(list) }
                        .disabled(list.isEmpty)
                }
                Button("Copy All Mappings") { engine.copyMappings() }
                    .disabled(engine.current?.mappings.isEmpty ?? true)
                Button("Paste Mappings") { engine.pasteMappings() }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy mappings, or paste mappings copied from another scene")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    @ViewBuilder
    private var hint: some View {
        if let source = engine.mapSource {
            banner("Click a knob to map \(Outputs.label(source, in: engine.current?.outputs ?? [])). Shift-click for several, Esc to finish.",
                   color: Theme.modulation) { engine.mapSource = nil }
        } else if let input = engine.current?.learningMIDI {
            banner("Learning: move controls on \(engine.deviceName(input.key)) to add them as outputs. Esc to finish.",
                   color: Theme.midi) { input.isLearning = false }
        }
    }

    private func banner(_ text: String, color: Color, cancel: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Done", action: cancel).controlSize(.small)
        }
        .padding(8)
        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.6)))
        .padding(.horizontal, 10).padding(.top, 10)
    }
}

private func empty(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
}

/// A collapsible section with an Ableton-style small caps header.
private struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    let key: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @AppStorage private var open: Bool

    init(_ title: String, key: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title; self.key = key
        self.accessory = accessory(); self.content = content()
        _open = AppStorage(wrappedValue: true, "inspector.section.\(key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button { open.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text(title.uppercased()).font(.system(size: 9, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            .frame(height: 18)
            if open { content }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
    }
}

// MARK: - Selected device

private struct DeviceInspector: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    let key: String

    var body: some View {
        let outputs = scene.outputs.filter { $0.deviceKey == key }
        let streams = scene.streamOutputs.filter { $0.deviceKey == key }
        let incoming = scene.mappings.filter { devicePath($0.target) == key }
        VStack(alignment: .leading, spacing: 1) {
            Text(engine.deviceName(key)).font(.system(size: 14, weight: .semibold))
            Text(kind).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.top, 12)

        InspectorSection("Outputs", key: "outputs") {
            ForEach(streams) { StreamOutputCard(scene: scene, stream: $0) }
            if outputs.isEmpty && streams.isEmpty {
                empty(key.hasPrefix("midi.")
                      ? "No controls yet. Turn on Learn on the device, then move the controls you want to use."
                      : "\(engine.deviceName(key)) has no outputs. Its knobs can still be driven by other devices' outputs.")
            }
            ForEach(outputs) { output in
                OutputCard(scene: scene, output: output)
            }
            if !outputs.isEmpty || !streams.isEmpty {
                Text("Click + then a knob (Shift-click for several), pick a knob from →, or drag an output onto a knob.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        let sockets = scene.streamInputs.filter { $0.deviceKey == key }
        if !sockets.isEmpty {
            InspectorSection("Inputs", key: "video-in") {
                ForEach(sockets) { StreamSocket(scene: scene, input: $0) }
                empty("Each takes one output of its kind: video from a Webcam, Spectrum or Audio Out from Audio In, Colours from the Palette, Sync from the Clock. Unmapped, video and spectrum are off, the palette is grey, LFOs run free, and the Clock doesn't follow the audio.")
            }
        }
        InspectorSection("Mapped Into \(engine.deviceName(key))", key: "incoming") {
            if incoming.isEmpty {
                empty("Nothing drives these knobs yet. Map an output onto one.")
            }
            ForEach(incoming) { MappingRow(mapping: $0) }
        }
    }

    private var kind: String {
        switch key {
        case "audio", "clock": return "Input"
        case _ where key.hasPrefix("webcam."): return "Input · Video"
        case "camera", "palette", "generator": return "Generation"
        default:
            if key.hasPrefix("mod.") {
                return "Modulation · " + (engine.current?.modulators.first { "mod.\($0.id)" == key }?.type.label ?? "")
            }
            return key.hasPrefix("midi.") ? "Input · MIDI" : "Effect"
        }
    }
}

/// One output of the selected device, with every mapping it drives underneath.
private struct OutputCard: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    let output: OutputSignal

    var body: some View {
        let mapped = scene.mappings.filter { $0.source == output.key }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                OutputRow(output: output)
                MapToMenu(scene: scene, output: output)
            }
            ForEach(mapped) { MappingRow(mapping: $0, showSource: false) }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if output.key.hasPrefix("midi.") {
                Button("Forget Control", role: .destructive) { engine.forgetMIDIControl(output.key) }
            }
        }
    }
}

/// A stream output of the selected device (video, spectrum or palette), with the inputs it
/// feeds underneath.
private struct StreamOutputCard: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    let stream: StreamOutput

    var body: some View {
        let mapping = engine.mapSource == stream.key
        let mapped = scene.mappings.filter { $0.source == stream.key }
        let noun = stream.kind.noun
        let targets = scene.streamInputs.filter { $0.kind == stream.kind }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: stream.kind.icon).font(.system(size: 10)).foregroundStyle(Theme.modulation)
                Text(stream.name).font(.system(size: 11)).foregroundStyle(mapping ? Theme.modulation : Theme.text)
                Text(noun).font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Button { engine.mapSource = mapping ? nil : stream.key } label: {
                    Image(systemName: mapping ? "scope" : "plus.circle").font(.system(size: 11, weight: mapping ? .bold : .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(mapping ? Theme.modulation : Theme.textDim)
                .help(mapping ? "Click a \(noun) input to map it. Click here to cancel." : "Map \(stream.name): click this, then a \(noun) input")
                Menu {
                    ForEach(targets) { input in
                        let done = mapped.contains { $0.target == input.key }
                        Button(done ? "✓ \(engine.targetLabel(input.key))" : engine.targetLabel(input.key)) {
                            engine.setStreamInput(input.key, stream.key)
                        }
                        .disabled(done)
                    }
                    if targets.isEmpty { Text("Nothing in the scene takes \(noun)") }
                } label: { Image(systemName: "arrow.forward.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Map \(stream.name) to a \(noun) input")
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .chainDragSource(.output(stream.key), engine: engine)
            ForEach(mapped) { MappingRow(mapping: $0, showSource: false) }
        }
        .padding(.vertical, 4)
    }
}

/// Every knob in the scene, by device, for mapping an output without leaving the inspector.
private struct MapToMenu: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    let output: OutputSignal

    var body: some View {
        Menu {
            ForEach(scene.deviceKeys, id: \.self) { path in
                if let bank = scene.banksByPath[path], !bank.params.isEmpty {
                    Menu(engine.deviceName(path)) {
                        ForEach(bank.params) { p in
                            let target = "\(path).\(p.def.name)"
                            let done = scene.mappings.contains { $0.source == output.key && $0.target == target }
                            Button(done ? "✓ \(knobLabel(p.def.name))" : knobLabel(p.def.name)) {
                                engine.addMapping(source: output.key, target: target)
                            }
                            .disabled(done)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.forward.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Map \(output.name) to a knob")
    }
}

// MARK: - Mappings

private struct MappingRow: View {
    @Environment(Engine.self) private var engine
    @Bindable var mapping: MappingRuntime
    /// Off when shown under its output, where the source is already clear.
    var showSource = true
    @State private var showMore = false

    var body: some View {
        let selected = engine.selectedTarget == mapping.target
        let color = mapping.source.hasPrefix("midi.") ? Theme.midi : Theme.modulation
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if mapping.kind.isStream {
                    Image(systemName: mapping.kind.icon).font(.system(size: 8)).foregroundStyle(color)
                } else {
                    Button(action: toggleEnabled) {
                        Circle().fill(mapping.enabled ? color : Theme.knobTrack).frame(width: 8, height: 8)
                    }
                    .buttonStyle(.plain)
                    .help(mapping.enabled ? "Turn off" : "Turn on")
                }
                VStack(alignment: .leading, spacing: 1) {
                    if showSource {
                        Text(mapping.sourceLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                    }
                    Text("→ \(mapping.targetLabel)").font(.system(size: 11, weight: showSource ? .regular : .medium))
                        .foregroundStyle(Theme.text)
                }
                .lineLimit(1)
                Spacer(minLength: 2)
                Button { engine.removeMapping(mapping) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
                .help("Remove mapping")
            }
            if let problem = mapping.problem {
                Label(problem, systemImage: "pause.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
            }
            if mapping.kind.isStream {
                Text(mapping.kind.rawValue.capitalized).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            } else {
            ContributionMeter(mapping: mapping, color: color)
            Group {
                SliderRow(label: "Amount", value: $mapping.amount, range: -1...1, text: percent(mapping.amount, signed: true))
                    .help("How far the output pushes the knob, as a share of its range. Negative pushes it down.")
                SliderRow(label: "Smooth", value: $mapping.smooth, range: 0...1,
                          text: mapping.smooth == 0 ? "off" : "\(Int(mapping.smooth * 1000)) ms")
                    .help("Glides the output, so fast hits become swells")
                if showMore {
                    SliderRow(label: "Curve", value: $mapping.curve, range: 0.25...4, text: String(format: "%.2f", mapping.curve))
                        .help("Below 1 boosts small values, above 1 keeps only strong ones")
                }
            }
            .disabled(!mapping.enabled)
            Button(showMore ? "Less" : "Curve…") { showMore.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.white.opacity(0.09) : Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? color.opacity(0.6) : .clear))
        .opacity(mapping.isActive ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture { engine.selectedTarget = mapping.target }
        .contextMenu {
            Button("Copy Mapping") { engine.copyMappings([mapping]) }
            Button("Remove", role: .destructive) { engine.removeMapping(mapping) }
        }
    }

    private func toggleEnabled() {
        let snapshot = engine.currentSnapshot()
        mapping.enabled.toggle()
        if let snapshot, let current = engine.currentSnapshot(), snapshot != current {
            engine.recordUndo(name: "Toggle Mapping", before: snapshot)
            engine.scheduleAutoSave()
        }
    }

    private func percent(_ v: Float, signed: Bool) -> String {
        let p = Int((v * 100).rounded())
        return signed && p > 0 ? "+\(p)%" : "\(p)%"
    }
}

/// What a mapping is adding to its knob right now: a bar from the centre, left for negative,
/// right for positive, spanning -100%...+100% of the knob's range, plus the amount in knob units.
private struct ContributionMeter: View {
    let mapping: MappingRuntime
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let c = mapping.contribution
            HStack(spacing: 6) {
                Canvas { ctx, size in
                    let mid = size.width / 2
                    ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 1), with: .color(Color(white: 0.1)))
                    let w = CGFloat(min(max(c, -1), 1)) * mid
                    ctx.fill(Path(CGRect(x: min(mid, mid + w), y: 0, width: abs(w), height: size.height)), with: .color(color.opacity(0.85)))
                    ctx.fill(Path(CGRect(x: mid - 0.5, y: -1, width: 1, height: size.height + 2)), with: .color(Theme.textDim))
                }
                .frame(height: 4)
                Text(text(c))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 46, alignment: .trailing)
            }
        }
        .help("What this mapping adds to the knob right now: centre is nothing, the ends are ±100% of the knob's range")
    }

    private func text(_ c: Float) -> String {
        guard let def = mapping.param?.def else { return "–" }
        let v = c * def.span
        let s = def.span >= 100 ? String(format: "%.0f", v) : def.span >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        return v > 0 && s.first != "-" && Float(s) != 0 ? "+" + s : s.hasPrefix("-") && Float(s) == 0 ? String(s.dropFirst()) : s
    }
}

private struct SliderRow: View {
    @Environment(Engine.self) private var engine
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let text: String
    @State private var dragSnapshot: SceneFile?

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textDim).frame(width: 44, alignment: .leading)
            Slider(value: $value, in: range) { isEditing in
                if isEditing {
                    dragSnapshot = engine.currentSnapshot()
                } else {
                    if let snapshot = dragSnapshot, let current = engine.currentSnapshot(), snapshot != current {
                        engine.recordUndo(name: "Adjust \(label)", before: snapshot)
                        engine.scheduleAutoSave()
                    }
                    dragSnapshot = nil
                }
            }
            .controlSize(.mini)
            Text(text).font(.system(size: 10).monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
    }
}
