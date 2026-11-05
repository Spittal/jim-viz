import Foundation

/// How many instances of a tool can be in the device chain: at most one, or any number.
enum ToolCardinality: String, CaseIterable, Codable, Hashable {
    case one
    case many
}

/// A device type you can put in a scene's chain, like an Ableton instrument or audio effect.
/// Each tool can have presets: saved knob values (and colors or mesh, where that applies).
struct Tool: Identifiable, Hashable {
    var id: String { "\(kind.rawValue):\(name)" }
    let kind: DeviceKind
    /// Tool id: `audio`, `clock`, `midi`, `orbit`, `palette`, a generator shader or an effect shader name.
    let name: String
    let label: String
    let cardinality: ToolCardinality
    let presets: [PresetInfo]

    var allowsMultiple: Bool { cardinality == .many }
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

    /// Cardinality of a tool: whether a scene can hold at most one or any number of it.
    static func cardinality(_ kind: DeviceKind, _ name: String) -> ToolCardinality {
        switch (kind, name) {
        case (.input, "audio"): return .one
        case (.input, "clock"): return .one
        case (.camera, _): return .one
        case (.palette, _): return .one
        case (.generator, _): return .many
        case (.modulation, _): return .many
        case (.effect, _): return .many
        case (.input, _): return .many
        }
    }

    /// Every tool, in chain order: inputs, modulation, cameras, palettes, generators, effects.
    static func all(_ store: ContentStore) -> [Tool] {
        func tool(_ kind: DeviceKind, _ name: String) -> Tool {
            let presets = store.presetIDs(kind, name).map { id -> PresetInfo in
                let p = store.preset(kind, name, id)
                return PresetInfo(id: id, name: p?.name ?? humanize(id), colors: p?.colors ?? [])
            }
            return Tool(kind: kind, name: name, label: label(kind, name), cardinality: cardinality(kind, name), presets: presets)
        }
        return [tool(.input, "audio"), tool(.input, "clock"), tool(.input, "midi"), tool(.input, "webcam"), tool(.modulation, "lfo"), tool(.camera, "orbit"), tool(.palette, "palette")]
            + store.generatorTypes().map { tool(.generator, $0) }
            + store.availableEffects().map { tool(.effect, $0) }
    }

    /// Colors a bare Palette starts with.
    static let defaultPalette = ["#000000", "#5A5A66", "#FFFFFF"]
}
