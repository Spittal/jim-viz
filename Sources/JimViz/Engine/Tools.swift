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
    /// Tool id: `audio`, `midi`, a camera rig (`orbit`, `static`…), a lens shader, `palette`, a generator shader or an effect shader name.
    let name: String
    let label: String
    let cardinality: ToolCardinality
    let presets: [PresetInfo]
    /// Generators: the category folder they live in (`lowpoly`), a browser section of its own.
    var category: String? = nil

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
        case (.modulation, _): return ModulatorType(rawValue: name)?.label ?? humanize(name)
        case (.input, "midi"): return "MIDI Input"
        case (.input, "webcam"): return "Webcam"
        case (.input, "video"): return "Video"
        case (.input, "picture"): return "Picture"
        case (.camera, _): return CameraRig(rawValue: name)?.label ?? humanize(name)
        case (.lens, "distortion"): return "Lens Distortion"
        case (.palette, _): return "Palette"
        case (.generator, "wheel"): return "Water Wheel"
        case (.effect, "kaleido"): return "Kaleidoscope"
        case (.effect, "palettemap"): return "Palette Map"
        case (.effect, "chroma"): return "Chromatic"
        case (.effect, "spectraltear"): return "Spectral Tear"
        default: return humanize(name)
        }
    }

    /// SF Symbol for a tool, in the browser and at the top left of its device.
    static func icon(_ kind: DeviceKind, _ name: String) -> String {
        switch kind {
        case .input:
            switch name {
            case "midi": return "pianokeys"
            case "webcam": return "video"
            case "video": return "play.rectangle"
            case "picture": return "photo"
            default: return "waveform"
            }
        case .modulation: return name == "math" ? "function" : name == "macro" ? "dial.medium" : "waveform.path"
        case .camera: return CameraRig(rawValue: name)?.icon ?? "camera.viewfinder"
        case .lens: return "camera.aperture"
        case .palette: return "paintpalette"
        case .generator:
            switch name {
            case "sphere": return "circle.circle"
            case "torus": return "circle.dotted.circle"
            case "plane": return "square.grid.3x3"
            case "cube": return "cube"
            case "shards": return "sparkle"
            case "wheel": return "fanblades"
            case "hand": return "hand.raised"
            case "dancer": return "figure.dance"
            case "street": return "building.2"
            default: return "cube.transparent"
            }
        case .effect:
            switch name {
            case "feedback": return "arrow.triangle.2.circlepath"
            case "warp": return "water.waves"
            case "kaleido": return "camera.filters"
            case "chroma": return "circle.lefthalf.filled"
            case "glitch": return "bolt.horizontal"
            case "palettemap": return "swatchpalette"
            case "pixelate": return "squareshape.split.3x3"
            case "glow": return "sun.max"
            case "film": return "film"
            case "mirror": return "arrow.left.and.right.square"
            case "slices": return "rectangle.split.3x1"
            case "composite": return "square.2.layers.3d"
            case "datamosh": return "square.on.square.dashed"
            case "echo": return "square.3.layers.3d.down.right"
            case "edges": return "pencil.and.outline"
            case "polar": return "scope"
            case "spectraltear": return "chart.bar.xaxis"
            default: return "sparkles"
            }
        }
    }

    /// Display name of a generator category folder.
    static func categoryLabel(_ category: String) -> String {
        switch category {
        case "lowpoly": return "Low Poly"
        default: return humanize(category)
        }
    }

    /// Cardinality of a tool: whether a scene can hold at most one or any number of it.
    static func cardinality(_ kind: DeviceKind, _ name: String) -> ToolCardinality {
        switch (kind, name) {
        case (.input, "audio"): return .one
        case (.camera, _): return .one
        case (.lens, _): return .one
        case (.palette, _): return .many
        case (.generator, _): return .many
        case (.modulation, _): return .many
        case (.effect, _): return .many
        case (.input, _): return .many
        }
    }

    /// Every tool, in chain order: inputs, modulation, cameras, lenses, palettes, generators, effects.
    static func all(_ store: ContentStore) -> [Tool] {
        func tool(_ kind: DeviceKind, _ name: String, category: String? = nil) -> Tool {
            let presets = store.presetIDs(kind, name).map { id -> PresetInfo in
                let p = store.preset(kind, name, id)
                return PresetInfo(id: id, name: p?.name ?? humanize(id), colors: p?.colors ?? [])
            }
            return Tool(kind: kind, name: name, label: label(kind, name), cardinality: cardinality(kind, name),
                        presets: presets, category: category)
        }
        return [tool(.input, "audio"), tool(.input, "midi"), tool(.input, "webcam"),
                tool(.input, "video"), tool(.input, "picture"),
                tool(.modulation, "lfo"), tool(.modulation, "math"), tool(.modulation, "macro")]
            + CameraRig.allCases.map { tool(.camera, $0.rawValue) } + store.availableLenses().map { tool(.lens, $0) }
            + [tool(.palette, "palette")]
            + store.generatorTypes().map { tool(.generator, $0.name, category: $0.category) }
            + store.availableEffects().map { tool(.effect, $0) }
    }

    /// Colors a bare Palette starts with.
    static let defaultPalette = ["#000000", "#5A5A66", "#FFFFFF"]
}
