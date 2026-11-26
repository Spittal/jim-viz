import Foundation
import Observation

/// MIDI for the whole app. Controls aren't a tool in the chain: each control is an output,
/// `midi.<control>` (`midi.cc-27-1`), holding its latest value from any connected device.
/// A scene maps controls onto its knobs and triggers, and its mappings save with it. This Mac
/// maps them onto the app's own targets: the Output knob and the playlist's Previous and Next.
///
/// MIDI map mode (the toolbar's keyboard button) maps by clicking: click a knob, trigger or
/// playlist button, then move a control.
///
/// Main thread, except `modulateOutput`, which the render thread calls once per frame.
@Observable
final class MIDIMap {
    /// MIDI map mode: clicks on knobs, triggers and playlist buttons pick what to learn.
    var isOn = false {
        didSet { if !isOn { learning = nil } }
    }
    /// The target waiting for a control: a scene knob or trigger, or an app target (`app.output`).
    var learning: String?

    /// The app's master fade, after the scenes are blended: 0 is black. Only the projector
    /// output and the preview are faded; feedback effects still see the unfaded picture.
    let output = Param(def: ParamDef(name: "output", defaultValue: 1, min: 0, max: 1, isInt: false))

    /// This Mac's MIDI mappings, onto app targets. Value mappings onto Output run on the render
    /// thread; trigger mappings onto the playlist fire on main as MIDI arrives.
    private(set) var appMappings: [MappingRuntime] = []

    @ObservationIgnored private var held: [MIDIControl: Held] = [:]
    @ObservationIgnored private let lock = NSLock()
    /// What the render thread runs: the outputs and mappings driving Output.
    @ObservationIgnored private var renderOutputs: [OutputSignal] = []
    @ObservationIgnored private var renderMappings: [MappingRuntime] = []
    /// Per playlist mapping: whether its control has dropped low enough to fire again, as for trigger inputs.
    @ObservationIgnored private var armed: [String: Bool] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var savedOutput: Float
    /// Why this Mac's saved MIDI mappings didn't load, for the status bar.
    @ObservationIgnored private(set) var loadError: String?

    final class Held { var value: Float = 0 }

    static let outputKey = "app.output"
    static let previousKey = "app.previous"
    static let nextKey = "app.next"
    static let appTargets = [outputKey, previousKey, nextKey]
    private static let mappingsDefaultsKey = "midi.mappings"
    private static let outputDefaultsKey = "output.level"

    static func isAppTarget(_ key: String) -> Bool { key.hasPrefix("app.") }

    static func label(_ target: String) -> String {
        switch target {
        case outputKey: return "Output"
        case previousKey: return "Previous Scene"
        case nextKey: return "Next Scene"
        default: return target
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        savedOutput = defaults.object(forKey: Self.outputDefaultsKey) as? Float ?? 1
        output.setBase(savedOutput)
        var specs: [MappingSpec] = []
        if let data = defaults.data(forKey: Self.mappingsDefaultsKey) {
            do { specs = try JSONDecoder().decode([MappingSpec].self, from: data) }
            catch { loadError = "\(Self.mappingsDefaultsKey) in this Mac's defaults: JSON invalid (\(error.localizedDescription))" }
        }
        rebuild(specs)
    }

    // MARK: Controls

    /// A control's latest value, shared by every scene, so a knob keeps a fader's position
    /// across a scene switch.
    func held(_ control: MIDIControl) -> Held {
        if let h = held[control] { return h }
        let h = Held()
        held[control] = h
        return h
    }

    /// An output reading a control, for a scene or this Mac's mappings.
    func makeOutput(_ control: MIDIControl) -> OutputSignal {
        let h = held(control)
        return OutputSignal(control.sourceKey, control.label, device: "MIDI") { _ in h.value }
    }

    func receive(_ control: MIDIControl, _ value: Float) {
        held(control).value = value
    }

    // MARK: App mappings

    var appSpecs: [MappingSpec] { appMappings.map(\.spec) }

    /// Replaces this Mac's mappings and saves them.
    func setAppMappings(_ specs: [MappingSpec]) {
        rebuild(specs)
        save()
    }

    /// Saves the mappings as they are, after their settings changed in the inspector.
    func save() {
        defaults.set(try! JSONEncoder.pretty.encode(appSpecs), forKey: Self.mappingsDefaultsKey)
    }

    /// Saves Output's knob when it has changed. Main, at UI rate.
    func saveOutputIfChanged() {
        guard output.base != savedOutput else { return }
        savedOutput = output.base
        defaults.set(savedOutput, forKey: Self.outputDefaultsKey)
    }

    private func rebuild(_ specs: [MappingSpec]) {
        var outputs: [String: OutputSignal] = [:]
        appMappings = specs.enumerated().map { i, spec in
            let control = MIDIControl(sourceKey: spec.source)
            let output = control.map { c in outputs[spec.source] ?? makeOutput(c) }
            if let output { outputs[spec.source] = output }
            let isOutput = spec.target == Self.outputKey
            var problem: String?
            if control == nil { problem = "Only MIDI controls map onto \(Self.label(spec.target))" }
            else if !Self.appTargets.contains(spec.target) { problem = "Unknown target \(spec.target)" }
            return MappingRuntime(id: "app\(i):\(spec.source)>\(spec.target)", spec: spec, kind: isOutput ? .value : .trigger,
                                  output: output, param: isOutput ? self.output : nil,
                                  sourceLabel: Outputs.label(spec.source, in: []), targetLabel: Self.label(spec.target),
                                  problem: problem)
        }
        let driving = appMappings.filter { $0.target == Self.outputKey && $0.isActive }
        output.isModulated = !driving.isEmpty
        if !output.isModulated { output.display = output.base; output.live = output.liveBase }
        armed = [:]
        lock.lock()
        renderOutputs = Array(outputs.values)
        renderMappings = driving
        lock.unlock()
    }

    /// Render thread, once per frame: Output's level after its mappings.
    func modulateOutput(_ f: SignalFrame) -> Float {
        lock.lock()
        let outputs = renderOutputs, mappings = renderMappings
        lock.unlock()
        guard !mappings.isEmpty else { return output.liveBase }
        for o in outputs { o.update(f) }
        output.modAccum = 0
        for m in mappings { m.modulate(f.dt) }
        output.live = output.def.clamp(output.liveBase + output.modAccum)
        return output.live
    }

    /// Main, as a control moves: the playlist targets its trigger mappings fire, each time the
    /// control rises past ½, re-arming below ¼.
    func firedTargets(_ control: MIDIControl, _ value: Float) -> [String] {
        var fired: [String] = []
        for m in appMappings where m.kind == .trigger && m.isActive && m.source == control.sourceKey {
            let armed = self.armed[m.id] ?? true
            if armed && value >= 0.5 {
                self.armed[m.id] = false
                fired.append(m.target)
            } else if value < 0.25 {
                self.armed[m.id] = true
            }
        }
        return fired
    }

    /// Main: a control just learned onto a trigger stays down, so it doesn't fire until released.
    func disarm(_ control: MIDIControl) {
        for m in appMappings where m.source == control.sourceKey { armed[m.id] = false }
    }
}
