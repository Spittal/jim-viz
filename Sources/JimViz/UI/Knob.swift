import SwiftUI

/// An Ableton-style rotary knob.
/// Drag vertically to change, hold Shift for fine control, double-click to reset.
/// Mappable knobs (those with a `targetPath`) also receive an output when clicked while one is
/// waiting to be mapped, or when one is dropped on them (the chain's drop delegate does the
/// routing), and show a cyan arc for the range their mappings can reach.
struct Knob: View {
    @Environment(Engine.self) private var engine
    let param: Param
    var targetPath: String? = nil
    @State private var dragStart: Float?
    @State private var dragSnapshot: SceneFile?

    private static let startAngle = 135.0
    private static let sweep = 270.0

    var body: some View {
        let mappable = targetPath != nil
        let mapMode = mappable && engine.mapSource.map { engine.kind(of: $0) == .value } ?? false
        let selected = mappable && engine.selectedTarget == targetPath && !mapMode
        let mappings = targetPath.map { engine.mappings(for: $0) } ?? []
        let dropHover = mappable && engine.dropKnob == targetPath

        VStack(spacing: 1) {
            Text(knobLabel(param.def.name))
                .font(Theme.labelFont)
                .foregroundStyle(selected ? Theme.text : Theme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

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
            // One tap handler: SwiftUI never fires a count-2 tap declared after a count-1 one.
            .onTapGesture {
                if let targetPath, engine.knobClicked(targetPath, keepMapping: NSEvent.modifierFlags.contains(.shift)) {
                    return
                }
                if NSApp.currentEvent?.clickCount == 2 {
                    let snapshot = engine.currentSnapshot()
                    param.reset()
                    if let snapshot, let current = engine.currentSnapshot(), snapshot != current {
                        engine.recordUndo(name: "Reset \(knobLabel(param.def.name))", before: snapshot)
                        engine.scheduleAutoSave()
                    }
                }
            }

            Text(valueText)
                .font(Theme.valueFont)
                .foregroundStyle(param.isModulated ? Theme.modulation : Theme.text)
                .lineLimit(1)
        }
        .frame(width: 54, height: 58)
        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.white.opacity(0.07) : .clear))
        .help(tooltip(mappings))
        // Outputs dropped here are routed by the chain's drop delegate, which finds the knob by frame.
        .chainFrame(targetPath.map { ChainDropDelegate.knobKey($0) } ?? "")
        .contextMenu { if let targetPath { menu(targetPath, mappings) } }
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
        let norm = { (v: Float) -> Double in Double((v - def.min) / max(def.span, 1e-6)) }
        let baseN = norm(param.base)
        let liveN = norm(param.display)
        let zeroN = def.min < 0 && def.max > 0 ? norm(0) : 0
        // The range modulation can reach: positive and negative amounts add up separately.
        let mods = mappings.filter { $0.isActive && $0.enabled }
        let up = Double(mods.reduce(Float(0)) { $0 + max($1.signedAmount, 0) })
        let down = Double(mods.reduce(Float(0)) { $0 + min($1.signedAmount, 0) })
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
                ctx.stroke(arc(baseN + down, baseN + up, radius: r + 2.5), with: .color(Theme.modulation.opacity(0.35)),
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
                    dragStart = param.base
                    dragSnapshot = engine.currentSnapshot()
                    if let targetPath { engine.selectedTarget = targetPath; engine.selectDevice(devicePath(targetPath)) }
                }
                let fine: Float = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                let delta = Float(-v.translation.height / 160) * param.def.span * fine
                param.setBase((dragStart ?? param.base) + delta)
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
        t += "\nDrag to change, Shift for fine, double-click to reset"
        if targetPath != nil { t += "\nDrop an output here, or right-click to map" }
        return t
    }
}
