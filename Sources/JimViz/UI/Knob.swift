import SwiftUI

/// An Ableton-style rotary knob.
/// Drag vertically to change, hold Shift for fine control, double-click to reset it, and
/// double-click its label to type a value (clamped to the knob's range). Once clicked, Delete
/// resets it and the up and down arrows step it (Shift for fine).
/// Mappable knobs (those with a `targetPath`) also receive an output when clicked while one is
/// waiting to be mapped, or when one is dropped on them (the chain's drop delegate does the
/// routing), and show a cyan arc for the range their mappings can reach.
struct Knob: View {
    @Environment(Engine.self) private var engine
    let param: Param
    var targetPath: String? = nil
    @State private var dragStart: Float?
    @State private var dragSnapshot: SceneFile?
    @State private var editText: String?
    @FocusState private var editFocused: Bool

    private static let startAngle = 135.0
    private static let sweep = 270.0

    var body: some View {
        let mappable = targetPath != nil
        let mapMode = mappable && engine.mapSource.map { engine.kind(of: $0) == .value } ?? false
        let selected = (mappable && engine.selectedTarget == targetPath || engine.activeKnob === param) && !mapMode
        let mappings = targetPath.map { engine.mappings(for: $0) } ?? []
        let dropHover = mappable && engine.dropKnob == targetPath

        VStack(spacing: 1) {
            Text(knobLabel(param.def.name))
                .font(Theme.labelFont)
                .foregroundStyle(selected ? Theme.text : Theme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentShape(Rectangle())
                .onTapGesture { click(double: startEdit) }

            ZStack {
                dial(mappings).frame(width: 30, height: 30)
                if mapMode || dropHover {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Theme.modulation, lineWidth: dropHover ? 2 : 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.modulation.opacity(dropHover ? 0.25 : 0.12)))
                }
            }
            .contentShape(Rectangle())
            .gesture(mapMode ? nil : drag)
            .onTapGesture { click(double: { engine.editKnob(param, "Reset") { param.reset() } }) }

            if let editText {
                TextField("", text: Binding(get: { editText }, set: { self.editText = $0 }))
                    .textFieldStyle(.plain)
                    .font(Theme.valueFont)
                    .multilineTextAlignment(.center)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.5)))
                    .focused($editFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { self.editText = nil }
                    .onChange(of: editFocused) { _, focused in if !focused { self.editText = nil } }
            } else {
                Text(valueText)
                    .font(Theme.valueFont)
                    .foregroundStyle(param.isModulated ? Theme.modulation : Theme.text)
                    .lineLimit(1)
            }
        }
        .frame(width: 54, height: 58)
        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.white.opacity(0.07) : .clear))
        .help(tooltip(mappings))
        // Outputs dropped here are routed by the chain's drop delegate, which finds the knob by frame.
        .chainFrame(targetPath.map { ChainDropDelegate.knobKey($0) } ?? "")
        .contextMenu { if let targetPath { menu(targetPath, mappings) } }
    }

    /// A click on the dial or label: maps a waiting output, or selects the knob and, on a
    /// double-click, runs `double`. One tap handler each, as SwiftUI never fires a count-2 tap
    /// declared after a count-1 one.
    private func click(double: () -> Void) {
        if let targetPath, engine.knobClicked(targetPath, keepMapping: NSEvent.modifierFlags.contains(.shift)) {
            return
        }
        engine.activeKnob = param
        if NSApp.currentEvent?.clickCount == 2 { double() }
    }

    private func startEdit() {
        editText = Knob.format(param.base, param.def)
        editFocused = true
    }

    /// Lets the up and down arrows step the active knob, even while the Scenes list has the
    /// keyboard focus (it keeps it after a click, and would switch scenes). With ⌘ they step
    /// to the previous or next scene, as ⌘[ and ⌘] do. Keys typed into a text field are left alone.
    static func installArrowKeys(_ engine: Engine) {
        guard arrowMonitor == nil else { return }
        arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let up = event.keyCode == 126, down = event.keyCode == 125
            let flags = event.modifierFlags
            guard up || down, flags.isDisjoint(with: [.option, .control]),
                  !(event.window?.firstResponder is NSText) else { return event }
            if flags.contains(.command) {
                guard !flags.contains(.shift) else { return event }
                engine.stepScene(up ? -1 : 1)
                return nil
            }
            guard engine.activeKnob != nil else { return event }
            engine.nudgeActiveKnob(up ? 1 : -1, fine: flags.contains(.shift))
            return nil
        }
    }
    nonisolated(unsafe) private static var arrowMonitor: Any?

    /// Applies a typed value, clamped to the knob's range. Int knobs also take a step's name.
    private func commitEdit() {
        defer { editText = nil }
        guard let text = editText?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return }
        let def = param.def
        if let i = def.labels.firstIndex(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
            engine.editKnob(param, "Set") { param.setBase(def.min + Float(i)) }
            return
        }
        let number = text.prefix { "0123456789.-+".contains($0) }
        guard let v = Float(number) else { return }
        engine.editKnob(param, "Set") { param.setBase(v) }
    }

    @ViewBuilder
    private func menu(_ target: String, _ mappings: [MappingRuntime]) -> some View {
        if let scene = engine.current {
            Menu("Map") {
                ForEach(Array(Dictionary(grouping: scene.outputs, by: \.device).sorted { a, b in
                    (scene.outputs.firstIndex { $0.device == a.key } ?? 0) < (scene.outputs.firstIndex { $0.device == b.key } ?? 0)
                }), id: \.key) { device, outputs in
                    Menu(device) {
                        ForEach(outputs) { o in
                            Button(o.name) { engine.addMapping(source: o.key, target: target) }
                        }
                    }
                }
            }
        }
        if !mappings.isEmpty {
            Divider()
            ForEach(mappings) { m in
                Button("Remove \(m.sourceLabel)") { engine.removeMapping(m) }
            }
            if mappings.count > 1 {
                Button("Remove All Mappings") { engine.removeMappings(target: target) }
            }
        }
    }

    private func dial(_ mappings: [MappingRuntime]) -> some View {
        let def = param.def
        let norm = { (v: Float) -> Double in Double(def.position(v)) }
        let baseN = norm(param.base)
        let liveN = norm(param.display)
        let zeroN = def.min < 0 && def.max > 0 ? norm(0) : 0
        // The range modulation can reach: positive and negative amounts add up separately.
        let mods = mappings.filter { $0.isActive && $0.enabled }
        let up = norm(param.base + mods.reduce(Float(0)) { $0 + max($1.signedAmount, 0) } * def.span)
        let down = norm(param.base + mods.reduce(Float(0)) { $0 + min($1.signedAmount, 0) } * def.span)
        let modulated = !mods.isEmpty
        return Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 3
            func arc(_ from: Double, _ to: Double, radius: CGFloat) -> Path {
                var p = Path()
                let lo = min(max(min(from, to), 0), 1), hi = min(max(max(from, to), 0), 1)
                p.addArc(center: c, radius: radius, startAngle: .degrees(Self.startAngle + Self.sweep * lo),
                         endAngle: .degrees(Self.startAngle + Self.sweep * hi), clockwise: false)
                return p
            }
            func point(_ n: Double, _ radius: CGFloat) -> CGPoint {
                let a = (Self.startAngle + Self.sweep * min(max(n, 0), 1)) * .pi / 180
                return CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
            }
            ctx.stroke(arc(0, 1, radius: r), with: .color(Theme.knobTrack), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            ctx.stroke(arc(zeroN, baseN, radius: r), with: .color(Theme.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            if modulated {
                ctx.stroke(arc(down, up, radius: r + 2.5), with: .color(Theme.modulation.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
                let dot = point(liveN, r + 2.5)
                ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 2, y: dot.y - 2, width: 4, height: 4)), with: .color(Theme.modulation))
            }
            var needle = Path()
            needle.move(to: point(baseN, r * 0.25))
            needle.addLine(to: point(baseN, r - 1))
            ctx.stroke(needle, with: .color(Theme.text), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragStart == nil {
                    dragStart = param.def.position(param.base)
                    dragSnapshot = engine.currentSnapshot()
                    if let targetPath { engine.selectedTarget = targetPath; engine.selectDevice(devicePath(targetPath)) }
                    engine.activeKnob = param
                }
                let fine: Float = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                // In knob positions, so a tapered knob moves finely where its low end is spread out.
                let delta = Float(-v.translation.height / 160) * fine
                let start = dragStart ?? param.def.position(param.base)
                param.setBase(param.def.value(atPosition: start + delta))
            }
            .onEnded { _ in
                if let snapshot = dragSnapshot, let current = engine.currentSnapshot(), snapshot != current {
                    engine.recordUndo(name: "Adjust \(knobLabel(param.def.name))", before: snapshot)
                    engine.scheduleAutoSave()
                }
                dragStart = nil
                dragSnapshot = nil
            }
    }

    private var valueText: String {
        Knob.format(param.isModulated ? param.display : param.base, param.def)
    }

    static func format(_ v: Float, _ def: ParamDef) -> String {
        if def.isInt {
            let i = Int(v.rounded()) - Int(def.min)
            return def.labels.indices.contains(i) ? def.labels[i] : String(Int(v.rounded()))
        }
        if def.name == "hz" {
            if v < 0.1 { return String(format: "%.3f Hz", v) }
            if v < 10 { return String(format: "%.2f Hz", v) }
            return String(format: "%.1f Hz", v)
        }
        let span = def.span
        if span >= 100 { return String(format: "%.0f", v) }
        if span >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    private func tooltip(_ mappings: [MappingRuntime]) -> String {
        let d = param.def
        var t = "\(d.name)  \(Knob.format(d.min, d))…\(Knob.format(d.max, d))  default \(Knob.format(d.defaultValue, d))"
        for m in mappings { t += "\n← \(m.sourceLabel)\(m.isActive ? "" : " (inactive)")" }
        t += "\nDrag to change, Shift for fine, double-click to reset, double-click the label to type a value, ↑↓ to step"
        if targetPath != nil { t += "\nDrop an output here, or right-click to map" }
        return t
    }
}
