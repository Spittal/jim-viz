import Foundation
import simd

// MARK: - Presets

/// Saved settings for one tool, in `Content/Presets/<kind>/<tool>/<id>.json`.
/// Fields that don't apply to a tool are left out (only palettes have colors,
/// only generators have shape and detail).
struct Preset: Codable {
    var name: String
    var params: [String: Float]?
    var colors: [String]?
    var shape: String?
    var detail: Int?
}

// MARK: - Scene

/// A scene is a composed device chain, left to right:
/// inputs (Audio In, Clock, MIDI, Webcam) → modulation (LFOs) → camera, palette, generator → effects.
/// Plus mappings, which route any tool's outputs (and MIDI controls) to any knob.
/// Each device names its tool and the preset it was loaded from; the preset's values are
/// copied in, so a scene never depends on (or changes) a preset file.
/// Edits happen in memory and are written with ⌘S.
struct SceneFile: Codable, Equatable {
    var name: String
    /// Signal sources, in chain order: at most one `audio` and one `clock`, any number of `midi`s.
    /// Without Audio In, audio signals read 0; without Clock, clock outputs aren't available.
    var inputs: [InputSpec]
    /// LFOs. Any number.
    var modulators: [ModulatorSpec]
    var camera: CameraSlot?
    var palette: PaletteSlot?
    var generator: GeneratorSlot?
    var generators: [GeneratorSlot]?
    var effects: [EffectSpec]
    var mappings: [MappingSpec]?

    var allGenerators: [GeneratorSlot] {
        get {
            if let list = generators, !list.isEmpty { return list }
            if let single = generator { return [single] }
            return []
        }
        set {
            if newValue.count <= 1 {
                generator = newValue.first
                generators = nil
            } else {
                generator = newValue.first
                generators = newValue
            }
        }
    }

    static func load(_ url: URL) throws -> SceneFile {
        try JSONDecoder().decode(SceneFile.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
        try JSONEncoder.pretty.encode(self).write(to: url, options: .atomic)
    }
}

extension SceneFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        inputs = try c.decodeIfPresent([InputSpec].self, forKey: .inputs) ?? []
        modulators = try c.decodeIfPresent([ModulatorSpec].self, forKey: .modulators) ?? []
        camera = try c.decodeIfPresent(CameraSlot.self, forKey: .camera)
        palette = try c.decodeIfPresent(PaletteSlot.self, forKey: .palette)
        generator = try c.decodeIfPresent(GeneratorSlot.self, forKey: .generator)
        generators = try c.decodeIfPresent([GeneratorSlot].self, forKey: .generators)
        effects = try c.decodeIfPresent([EffectSpec].self, forKey: .effects) ?? []
        mappings = try c.decodeIfPresent([MappingSpec].self, forKey: .mappings)
    }
}

struct ModulatorSpec: Codable, Equatable {
    /// Modulator tool. Only `lfo` exists so far.
    var type: String
    /// Unique id within the scene: `mod.<id>.out` as a source, `mod.<id>.<param>` as a target.
    var id: String
    var preset: String?
    var enabled: Bool?
    var params: [String: Float]?
}

struct InputSpec: Codable, Equatable {
    /// Input tool: `audio`, `clock`, `midi` or `webcam`.
    var type: String
    /// MIDI inputs and webcams: unique id within the scene. `midi.<id>` and `webcam.<id>` in
    /// mapping keys (`midi.<id>.cc-31-7`, `webcam.<id>.motion`, `webcam.<id>.<param>`).
    var id: String?
    /// Audio In: the source, required: `rekordbox`, `system` or `input:<device uid>`.
    /// MIDI and webcam: the device by name. Leave out for every MIDI device, or the default camera.
    var device: String?
    /// Audio In: which stereo pair of the source to listen to, 0 (channels 1–2) when left out.
    var channelPair: Int?
    /// MIDI: learned controls, which are its outputs (`cc-31-7`, `note-11-1`, `pb-0-1`).
    var controls: [String]?
    var preset: String?
    var enabled: Bool?
    var params: [String: Float]?

    var isMIDI: Bool { type == "midi" }
    var isWebcam: Bool { type == "webcam" }
    /// Chain key: `audio`, `clock`, `midi.<id>` or `webcam.<id>`.
    var deviceKey: String { isMIDI || isWebcam ? "\(type).\(id ?? type)" : type }
}

struct CameraSlot: Codable, Equatable {
    /// Camera tool. Only `orbit` exists so far.
    var type: String
    /// Preset it was loaded from, for display.
    var preset: String?
    var params: [String: Float]?
}

struct PaletteSlot: Codable, Equatable {
    var preset: String?
    var colors: [String]
    /// The palette's inputs: red, green, blue, hue, saturation, brightness.
    var params: [String: Float]?
}

struct GeneratorSlot: Codable, Identifiable, Equatable {
    /// Unique id within the scene, used in mapping targets when multiple are present.
    var id: String?
    /// Generator tool: a shader in Shaders/generators, without extension.
    var type: String
    /// Preset it was loaded from, for display.
    var preset: String?
    /// Mesh shape: icosphere, torus, plane, cube, shards, field (a 16:9 sheet for depth and video).
    var shape: String?
    /// Mesh subdivision level, 0...6.
    var detail: Int?
    /// Knob values; unlisted knobs use the shader's defaults.
    var params: [String: Float]?
}

struct EffectSpec: Codable, Equatable {
    /// Shader file in Shaders/effects, without extension.
    var effect: String
    /// Unique id within the scene, used in mapping targets (`post.<id>.<param>`).
    var id: String?
    /// Preset it was loaded from, for display.
    var preset: String?
    var enabled: Bool?
    var params: [String: Float]?
}

struct MappingSpec: Codable, Equatable {
    /// A value output (`audio.kick`, `clock.pulse`, `mod.lfo.out`, `midi.midi.cc-31-7`, `camera.angle`)
    /// or a stream output (`webcam.<id>.video`, `audio.spectrum`, `palette.colors`).
    var source: String
    /// A knob (`generator.<param>`, `camera.<param>`, `post.<id>.<param>`, `mod.<id>.<param>`,
    /// `webcam.<id>.<param>`) for a value, or a stream input of the same kind
    /// (`generator.bgVideo`, `generator.spec`, `generator.pal`) for a stream.
    var target: String
    /// Value mappings: fraction of the knob's range added at full signal, -1...1. Negative pushes down.
    var amount: Float?
    /// Exponent applied to the 0...1 signal before scaling. 1 is linear.
    var curve: Float?
    /// Modulation smoothing time in seconds.
    var smooth: Float?
    var enabled: Bool?

    init(source: String, target: String, amount: Float? = nil) {
        self.source = source; self.target = target; self.amount = amount
    }
}

/// Converts `#RRGGBB` to linear-ish 0...1 RGB.
func parseHexColor(_ s: String) -> SIMD3<Float>? {
    var hex = s.trimmingCharacters(in: .whitespaces)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return SIMD3(Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255
}

func hexString(_ c: SIMD3<Float>) -> String {
    let q = (simd_clamp(c, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)) * Float(255)).rounded(.toNearestOrAwayFromZero)
    return String(format: "#%02X%02X%02X", Int(q.x), Int(q.y), Int(q.z))
}

/// "terrain-scan" → "Terrain Scan".
func humanize(_ s: String) -> String {
    s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.capitalized }.joined(separator: " ")
}

func slugify(_ s: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    let slug = String(s.lowercased().map { $0 == " " ? "-" : $0 }.filter { allowed.contains($0) })
    return slug.isEmpty ? "scene" : slug
}

/// Knob name as shown: "noiseAmount" → "noise amount".
func knobLabel(_ name: String) -> String {
    name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return enc
    }
}
