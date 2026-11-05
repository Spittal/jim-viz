import SwiftUI

/// The scene's device chain, processed left to right in three sections:
/// INPUTS (Audio In, Clock, MIDI, Webcam) | MODULATION (LFOs) | GENERATION (camera, palette,
/// one generator) | EFFECTS.
/// Devices come from the browser by drag or double-click; effects reorder by dragging their header.
/// Click a device to select it: the inspector then shows its outputs and mappings.
struct DeviceChain: View {
    @Environment(Engine.self) private var engine
    let scene: RenderScene
    @State private var frames: [String: CGRect] = [:]
    @State private var dropTarget: ChainDropTarget?

    var body: some View {
        let effectIDs = scene.effects.map(\.id)
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    // Inputs
                    ForEach(scene.inputs) { input in
                        switch input {
                        case .audio(let a):
                            AudioDevice(input: a, accent: isReplacing(key: "audio", kind: .input))
                                .contextMenu {
                                    Button("Remove", role: .destructive) { engine.removeInput("audio") }
                                }
                                .chainFrame("device:input:audio:audio")
                        case .clock(let c):
                            ClockDevice(clock: c, accent: isReplacing(key: "clock", kind: .input))
                                .contextMenu {
                                    Button("Remove", role: .destructive) { engine.removeInput("clock") }
                                }
                                .chainFrame("device:input:clock:clock")
                        case .midi(let input):
                            MIDIInputDevice(input: input, accent: isReplacing(key: input.id, kind: .input))
                                .chainFrame("device:input:\(input.id):midi")
                        case .webcam(let w):
                            WebcamDevice(webcam: w, accent: isReplacing(key: w.id, kind: .input))
                                .chainFrame("device:input:\(w.id):webcam")
                        }
                    }
                    Color.clear.frame(width: 4).frame(maxHeight: .infinity)
                        .chainFrame("inputs.end")

                    sectionDivider

                    // Modulation
                    if !scene.modulators.isEmpty {
                        ForEach(Array(scene.modulators.enumerated()), id: \.element.id) { index, mod in
                            LFODevice(mod: mod, accent: isReplacing(key: mod.id, kind: .modulation))
                                .contextMenu {
                                    Button("Move Left") { engine.moveModulator(id: mod.id, by: -1) }.disabled(index == 0)
                                    Button("Move Right") { engine.moveModulator(id: mod.id, by: 1) }
                                        .disabled(index == scene.modulators.count - 1)
                                    Divider()
                                    Button("Remove", role: .destructive) { engine.removeModulator(id: mod.id) }
                                }
                                .chainFrame("device:modulation:\(mod.id):\(mod.type)")
                        }
                        Color.clear.frame(width: 4).frame(maxHeight: .infinity)
                            .chainFrame("modulators.end")
                        sectionDivider
                    }

                    // Generation
                    if let cam = scene.camera {
                        DevicePanel(title: "Camera", subtitle: scene.cameraLabel, accent: slotColor(.camera, key: "camera"), select: "camera",
                                    onClose: { engine.removeCamera() }) {
                            KnobGrid(params: cam.params, prefix: "camera")
                        }
                        .contextMenu {
                            Button("Remove", role: .destructive) { engine.removeCamera() }
                        }
                        .chainFrame("device:camera:camera:\(scene.cameraMotion?.rig.rawValue ?? "orbit")")
                    }
                    if let pal = scene.palette {
                        DevicePanel(title: "Palette", subtitle: scene.paletteLabel, accent: slotColor(.palette, key: "palette"), select: "palette",
                                    onClose: { engine.removePalette() }) {
                            HStack(alignment: .top, spacing: 6) {
                                PaletteEditor(palette: pal)
                                KnobGrid(params: pal.bank.params, prefix: "palette")
                            }
                        }
                        .contextMenu {
                            Button("Remove", role: .destructive) { engine.removePalette() }
                        }
                        .chainFrame("device:palette:palette:palette")
                    }
                    ForEach(Array(scene.generators.enumerated()), id: \.element.id) { index, gen in
                        DevicePanel(title: "Generator", subtitle: gen.label ?? gen.type,
                                    accent: slotColor(.generator, key: gen.key), select: gen.key, onClose: { engine.removeGenerator(key: gen.key) }) {
                            VStack(alignment: .leading, spacing: 6) {
                                // Stream sockets only show while a stream of their kind is waiting to be mapped.
                                let waiting = engine.mapSource.map { engine.kind(of: $0) }
                                let sockets = scene.streamInputs.filter { $0.deviceKey == gen.key && $0.kind == waiting }
                                if !sockets.isEmpty {
                                    HStack(spacing: 4) { ForEach(sockets) { StreamSocket(scene: scene, input: $0) } }
                                }
                                KnobGrid(params: gen.bank.params, prefix: gen.key)
                            }
                        }
                        .contextMenu {
                            Button("Move Left") { engine.moveGenerator(key: gen.key, by: -1) }.disabled(index == 0)
                            Button("Move Right") { engine.moveGenerator(key: gen.key, by: 1) }.disabled(index == scene.generators.count - 1)
                            Divider()
                            Button("Remove", role: .destructive) { engine.removeGenerator(key: gen.key) }
                        }
                        .chainFrame("device:generator:\(gen.key):\(gen.type)")
                    }
                    Color.clear.frame(width: 4).frame(maxHeight: .infinity)
                        .chainFrame("generators.end")

                    sectionDivider

                    // Effects
                    ForEach(Array(scene.effects.enumerated()), id: \.element.id) { index, fx in
                        EffectDevice(fx: fx, accent: isReplacing(key: fx.id, kind: .effect))
                            .contextMenu {
                                Button("Move Left") { engine.moveEffect(id: fx.id, to: index - 1) }.disabled(index == 0)
                                Button("Move Right") { engine.moveEffect(id: fx.id, to: index + 2) }
                                    .disabled(index == scene.effects.count - 1)
                                Divider()
                                Button("Remove", role: .destructive) { engine.removeEffect(id: fx.id) }
                            }
                            .chainFrame(fx.id)
                            .chainFrame("device:effect:\(fx.id):\(fx.effect)")
                    }
                    // Where an effect dropped at the end lands, and where its marker draws.
                    Color.clear.frame(width: 24).frame(maxHeight: .infinity)
                        .chainFrame(ChainDropDelegate.endKey)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .frame(minWidth: geo.size.width, alignment: .topLeading)
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                // Clicking empty chain space clears the selection.
                .onTapGesture { engine.selectDevice(nil) }
                .coordinateSpace(name: ChainDropDelegate.space)
                .onPreferenceChange(ChainFrameKey.self) { frames = $0 }
                .overlay(alignment: .topLeading) { insertionMarker(effectIDs) }
                .onDrop(of: [.plainText],
                        delegate: ChainDropDelegate(engine: engine, effectIDs: effectIDs, frames: frames, target: $dropTarget))
                .onChange(of: dropTarget) { _, t in
                    if case .knob(let path)? = t { engine.dropKnob = path } else { engine.dropKnob = nil }
                }
            }
            .scrollIndicators(.visible)
        }
        .background(Theme.chainBackground)
    }

    private var sectionDivider: some View {
        Rectangle().fill(Theme.deviceBorder).frame(width: 2).padding(.vertical, 4)
    }

    private func isSlot(_ kind: DeviceKind) -> Bool { dropTarget == .replace(kind) }

    private func isReplacing(key: String, kind: DeviceKind) -> Color? {
        if case .replaceDevice(let k, let kd, _) = dropTarget, k == key && kd == kind {
            return Theme.accent
        }
        return nil
    }

    private func slotColor(_ kind: DeviceKind, key: String? = nil) -> Color? {
        if dropTarget == .replace(kind) { return Theme.accent }
        if let key, isReplacing(key: key, kind: kind) != nil { return Theme.accent }
        return nil
    }

    /// Ableton-style insertion line while a device is dragged over the chain.
    @ViewBuilder
    private func insertionMarker(_ ids: [String]) -> some View {
        if case .effectIndex(let i)? = dropTarget,
           let x = ChainDropDelegate.markerX(i, ids: ids, frames: frames),
           let frame = frames[i < ids.count ? ids[i] : ChainDropDelegate.endKey] {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.accent)
                .frame(width: 3, height: frame.height)
                .offset(x: x, y: frame.minY)
                .allowsHitTesting(false)
        } else if case .generatorIndex(let i)? = dropTarget {
            let genKeys = frames.keys
                .filter { $0.hasPrefix("device:generator:") }
                .sorted { (frames[$0]?.minX ?? 0) < (frames[$1]?.minX ?? 0) }
            let targetKey = i < genKeys.count ? genKeys[i] : "generators.end"
            if let frame = frames[targetKey] {
                let x = i < genKeys.count ? (frame.minX - 4.5) : (frame.minX - 1.5)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3, height: frame.height)
                    .offset(x: x, y: frame.minY)
                    .allowsHitTesting(false)
            }
        } else if case .modulatorIndex(let i)? = dropTarget {
            let modKeys = frames.keys
                .filter { $0.hasPrefix("device:modulation:") }
                .sorted { (frames[$0]?.minX ?? 0) < (frames[$1]?.minX ?? 0) }
            let targetKey = i < modKeys.count ? modKeys[i] : "modulators.end"
            if let frame = frames[targetKey] {
                let x = i < modKeys.count ? (frame.minX - 4.5) : (frame.minX - 1.5)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3, height: frame.height)
                    .offset(x: x, y: frame.minY)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct EffectDevice: View {
    @Environment(Engine.self) private var engine
    @Bindable var fx: EffectRuntime
    var accent: Color? = nil

    var body: some View {
        DevicePanel(title: fx.id, subtitle: fx.presetLabel, isOn: $fx.enabled, failed: fx.pipeline == nil,
                    accent: accent,
                    drag: .move(effectID: fx.id), select: "post.\(fx.id)", onClose: { engine.removeEffect(id: fx.id) }) {
            if fx.bank.params.isEmpty {
                Text(fx.pipeline == nil ? "shader error" : "no params")
                    .font(Theme.labelFont)
                    .foregroundStyle(fx.pipeline == nil ? Theme.error : Theme.textDim)
                    .frame(width: 60, height: 60)
            } else {
                KnobGrid(params: fx.bank.params, prefix: "post.\(fx.id)")
            }
        }
    }
}

/// Knobs laid out in columns of three, like an Ableton device, optionally grouped into
/// categories with visual separators and conditional on active stream mappings.
struct KnobGrid: View {
    @Environment(Engine.self) private var engine
    let params: [Param]
    var prefix: String = ""
    private let rows = 3

    var body: some View {
        let visibleParams = filterVisible(params)
        let groups = groupParams(visibleParams)

        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1)
                        .padding(.vertical, 4)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let title = group.title {
                        Text(title.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                    HStack(alignment: .top, spacing: 2) {
                        let count = (group.params.count + rows - 1) / rows
                        ForEach(0..<count, id: \.self) { col in
                            VStack(spacing: 4) {
                                ForEach(group.params[col * rows ..< min(group.params.count, (col + 1) * rows)]) { p in
                                    Knob(param: p, targetPath: prefix.isEmpty ? nil : "\(prefix).\(p.def.name)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func filterVisible(_ list: [Param]) -> [Param] {
        guard let scene = engine.current, !prefix.isEmpty else { return list }
        return list.filter { p in
            guard let req = p.def.requiresInput else { return true }
            return scene.streamBindings["\(prefix).\(req)"] != nil
        }
    }

    private struct ParamGroup {
        let title: String?
        let params: [Param]
    }

    private func groupParams(_ list: [Param]) -> [ParamGroup] {
        var groups: [ParamGroup] = []
        var currentTitle: String? = nil
        var currentParams: [Param] = []

        for p in list {
            if p.def.group != currentTitle {
                if !currentParams.isEmpty {
                    groups.append(ParamGroup(title: currentTitle, params: currentParams))
                    currentParams = []
                }
                currentTitle = p.def.group
            }
            currentParams.append(p)
        }
        if !currentParams.isEmpty {
            groups.append(ParamGroup(title: currentTitle, params: currentParams))
        }
        return groups
    }
}

struct DevicePanel<Content: View>: View {
    @Environment(Engine.self) private var engine
    let title: String
    var subtitle: String? = nil
    var isOn: Binding<Bool>? = nil
    var failed = false
    var statusColor: Color? = nil
    /// Outline shown while a matching drag hovers.
    var accent: Color? = nil
    /// Makes the header a drag handle (knobs below stay free to turn).
    var drag: ChainDrag? = nil
    /// Chain key; clicking the device selects it.
    var select: String? = nil
    /// Less-used settings, opened from a button in the header next to the close button.
    var settings: AnyView? = nil
    var settingsHelp = "Settings"
    var onClose: (() -> Void)? = nil
    @State private var showSettings = false
    @ViewBuilder let content: Content

    private var selected: Bool { select != nil && engine.selectedDevice == select }

    private var collapsed: Bool { select.map(engine.isCollapsed) ?? false }

    var body: some View {
        let on = isOn?.wrappedValue ?? true
        Group {
            if collapsed {
                folded(on)
            } else {
                VStack(spacing: 0) {
                    header
                    content
                        .padding(6)
                        .opacity(on ? 1 : 0.4)
                    Spacer(minLength: 0)
                }
            }
        }
        // Every device fills the chain's height, like Ableton.
        .frame(maxHeight: .infinity)
        .background(on ? Theme.device : Theme.deviceOff)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(accent ?? (selected ? Theme.selection : Theme.deviceBorder), lineWidth: accent == nil && !selected ? 1 : 1.5))
        .contentShape(Rectangle())
        // Knobs and buttons handle their own clicks; anywhere else selects the device.
        .onTapGesture { if let select { engine.selectDevice(select) } }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var header: some View {
        if let drag {
            bar.chainDragSource(drag, engine: engine).help("Drag the header to reorder. Double-click to fold.")
        } else {
            bar.help("Double-click to fold")
        }
    }

    private func toggleOn() {
        guard let isOn else { return }
        let snapshot = engine.currentSnapshot()
        isOn.wrappedValue.toggle()
        if let snapshot, let current = engine.currentSnapshot(), snapshot != current {
            engine.recordUndo(name: "Toggle \(title)", before: snapshot)
            engine.scheduleAutoSave()
        }
    }
    private func headerClicked() {
        guard let select else { return }
        if NSApp.currentEvent?.clickCount == 2 { engine.toggleCollapsed(select) }
        engine.selectDevice(select)
    }

    /// A folded device: a narrow strip with its name running up the side, like Ableton.
    @ViewBuilder
    private func folded(_ on: Bool) -> some View {
        let strip = VStack(spacing: 8) {
            if isOn != nil {
                Button(action: toggleOn) {
                    Circle().fill(on ? Theme.accent : Theme.knobTrack).frame(width: 9, height: 9)
                }
                .buttonStyle(.plain)
            } else if let statusColor {
                Circle().fill(statusColor).frame(width: 8, height: 8)
            }
            Text(subtitle.map { "\(title)  \($0)" } ?? title)
                .font(Theme.titleFont)
                .foregroundStyle(failed ? Theme.error : Theme.text)
                .lineLimit(1)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 20, height: 20)
                .frame(maxHeight: .infinity)
        }
        .padding(.vertical, 6)
        .frame(width: 22)
        .frame(maxHeight: .infinity)
        .background(selected ? Theme.deviceHeaderSelected : Theme.deviceHeader)
        .contentShape(Rectangle())
        .onTapGesture(perform: headerClicked)
        .help("\(title). Double-click to unfold.")
        if let drag { strip.chainDragSource(drag, engine: engine) } else { strip }
    }

    private var bar: some View {
        let on = isOn?.wrappedValue ?? true
        return HStack(spacing: 6) {
            if isOn != nil {
                Button(action: toggleOn) {
                    Circle().fill(on ? Theme.accent : Theme.knobTrack).frame(width: 9, height: 9)
                }
                .buttonStyle(.plain)
                .help(on ? "Turn off" : "Turn on")
            }
            if let statusColor {
                Circle().fill(statusColor).frame(width: 8, height: 8)
            }
            Text(title)
                .font(Theme.titleFont)
                .foregroundStyle(failed ? Theme.error : Theme.text)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 4)
            if let settings {
                Button { showSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(showSettings ? Theme.text : Theme.textDim)
                .help(settingsHelp)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings }
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
                .help("Remove")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(selected ? Theme.deviceHeaderSelected : Theme.deviceHeader)
        .contentShape(Rectangle())
        .onTapGesture(perform: headerClicked)
    }
}

// MARK: - Palette Editor

/// Swatches for each palette color, plus the resulting gradient.
struct PaletteEditor: View {
    @Environment(Engine.self) private var engine
    let palette: PaletteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The palette as it renders, with its inputs (and their modulation) applied.
            let shown = palette.colors.map { c in PaletteParams.adjust(c) { palette.bank[$0]?.display ?? 1 } }
            LinearGradient(colors: shown.map(Self.color), startPoint: .leading, endPoint: .trailing)
                .frame(width: 150, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .help("The palette as it renders, after red, green, blue, hue, saturation and brightness")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                ForEach(palette.colors.indices, id: \.self) { i in
                    ColorWell(color: palette.colors[i]) { updateColor(at: i, to: $0) }
                        .frame(width: 28, height: 20)
                }
            }
            HStack(spacing: 4) {
                Button { replaceColors(palette.colors + [palette.colors.last ?? .one]) } label: { Image(systemName: "plus") }
                Button { replaceColors(Array(palette.colors.dropLast())) } label: { Image(systemName: "minus") }
                    .disabled(palette.colors.count <= 2)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .frame(width: 150, alignment: .leading)
    }

    private func updateColor(at index: Int, to color: SIMD3<Float>) {
        let snapshot = engine.currentSnapshot()
        palette.set(index, color)
        if let snapshot, let current = engine.currentSnapshot(), snapshot != current {
            engine.recordUndo(name: "Edit Palette", before: snapshot)
            engine.scheduleAutoSave()
        }
    }

    private func replaceColors(_ newColors: [SIMD3<Float>]) {
        let snapshot = engine.currentSnapshot()
        palette.replace(newColors)
        if let snapshot, let current = engine.currentSnapshot(), snapshot != current {
            engine.recordUndo(name: "Edit Palette Colors", before: snapshot)
            engine.scheduleAutoSave()
        }
    }

    static func color(_ c: SIMD3<Float>) -> Color {
        Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}

/// A palette swatch. Clicking opens the system color panel bound to this swatch.
struct ColorWell: View {
    let color: SIMD3<Float>
    let onChange: (SIMD3<Float>) -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(PaletteEditor.color(color))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.25), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { ColorPanelBridge.shared.edit(color, onChange: onChange) }
            .help(hexString(color))
    }
}

/// Routes the shared NSColorPanel to whichever swatch was clicked last.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((SIMD3<Float>) -> Void)?

    func edit(_ color: SIMD3<Float>, onChange: @escaping (SIMD3<Float>) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.color = NSColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        self.onChange = onChange
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        guard let c = panel.color.usingColorSpace(.sRGB) else { return }
        onChange?(SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)))
    }
}
