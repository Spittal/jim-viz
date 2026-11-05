import Foundation

/// A device type you can put in a scene's chain, like an Ableton instrument or audio effect.
/// Each tool can have presets: saved knob values (and colors or mesh, where that applies).
struct Tool: Identifiable, Hashable {
    var id: String { "\(kind.rawValue):\(name)" }
    let kind: DeviceKind
    /// Tool id: `audio`, `clock`, `midi`, `orbit`, `palette`, a generator shader or an effect shader name.
    let name: String
    let label: String
    let presets: [PresetInfo]
}

struct PresetInfo: Identifiable, Hashable {
    let id: String
    let name: String
    /// Palette colors, for the browser swatch.
    let colors: [String]
}

enum Tools {
    /// Display names where the file name doesn't read well.
    static func label(_ kind: DeviceKind, _ name: String) -> String {
        switch (kind, name) {
        case (.input, "audio"): return "Audio In"
        case (.input, "clock"): return "Clock"
        case (.modulation, "lfo"): return "LFO"
        case (.input, "midi"): return "MIDI Input"
        case (.input, "webcam"): return "Webcam"
        case (.camera, "orbit"): return "Orbit Camera"
        case (.palette, _): return "Palette"
        case (.generator, "lowpoly"): return "Low Poly"
        case (.effect, "kaleido"): return "Kaleidoscope"
        case (.effect, "palettemap"): return "Palette Map"
        case (.effect, "chroma"): return "Chromatic"
        default: return humanize(name)
        }
    }

    /// Every tool, in chain order: inputs, modulation, cameras, palettes, generators, effects.
    static func all(_ store: ContentStore) -> [Tool] {
        func tool(_ kind: DeviceKind, _ name: String) -> Tool {
            let presets = store.presetIDs(kind, name).map { id -> PresetInfo in
                let p = store.preset(kind, name, id)
                return PresetInfo(id: id, name: p?.name ?? humanize(id), colors: p?.colors ?? [])
            }
            return Tool(kind: kind, name: name, label: label(kind, name), presets: presets)
        }
        return [tool(.input, "audio"), tool(.input, "clock"), tool(.input, "midi"), tool(.input, "webcam"), tool(.modulation, "lfo"), tool(.camera, "orbit"), tool(.palette, "palette")]
            + store.generatorTypes().map { tool(.generator, $0) }
            + store.availableEffects().map { tool(.effect, $0) }
    }

    /// Colors a bare Palette starts with.
    static let defaultPalette = ["#000000", "#5A5A66", "#FFFFFF"]
}
