import Foundation
import simd

// MARK: - Presets

/// Saved settings for one tool, in `<library>/Presets/<kind>/<tool>/<id>.json`.
/// Fields that don't apply to a tool are left out (only palettes have colors).
struct Preset: Codable {
    var name: String
    var params: [String: Float]?
    var colors: [String]?
}

// MARK: - Scene

/// A scene is a composed device chain, left to right:
/// inputs (Audio In, MIDI, Webcam) → modulation (LFOs) → camera, lens, palette, generators → effects.
/// Plus mappings, which route any tool's outputs (and MIDI controls) to any knob.
/// Each device names its tool and the preset it was loaded from; the preset's values are
/// copied in, so a scene never depends on (or changes) a preset file.
/// Edits happen in memory and are written with ⌘S.
struct SceneFile: Codable, Equatable {
    var name: String
    /// Signal sources, in chain order: at most one `audio`, any number of the rest.
    /// Without Audio In, audio signals read 0 and there's no beat.
    var inputs: [InputSpec]
    /// LFOs and Maths. Any number.
    var modulators: [ModulatorSpec]
    var camera: CameraSlot?
    /// The camera effect: a lens whose ST map the Camera's Lens input can take.
    var lens: LensSlot? = nil
    /// Palettes, in chain order. The first is keyed `palette`, the rest `palette.<id>`.
    var palettes: [PaletteSlot]
    /// Generators, in chain order. The first is keyed `generator`, the rest `generator.<id>`.
    var generators: [GeneratorSlot]
    var effects: [EffectSpec]
    var mappings: [MappingSpec]?

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
        lens = try c.decodeIfPresent(LensSlot.self, forKey: .lens)
        palettes = try c.decodeIfPresent([PaletteSlot].self, forKey: .palettes) ?? []
        generators = try c.decodeIfPresent([GeneratorSlot].self, forKey: .generators) ?? []
        effects = try c.decodeIfPresent([EffectSpec].self, forKey: .effects) ?? []
        mappings = try c.decodeIfPresent([MappingSpec].self, forKey: .mappings)
    }
}

struct ModulatorSpec: Codable, Equatable {
    /// Modulator tool: `lfo` or `math`.
    var type: String
    /// Unique id within the scene: `mod.<id>.out` as a source, `mod.<id>.<param>` as a target.
    var id: String
    var preset: String?
    var enabled: Bool?
    var params: [String: Float]?
}

struct InputSpec: Codable, Equatable {
    /// Input tool: `audio`, `midi`, `webcam`, `video` or `picture`.
    var type: String
    /// MIDI inputs, webcams, videos, pictures: unique id within the scene. `midi.<id>`,
    /// `webcam.<id>`, `video.<id>`, `picture.<id>` in mapping keys.
    var id: String?
    /// Audio In: the source, required: `rekordbox`, `system` or `input:<device uid>`.
    /// MIDI and webcam: the device by name. Leave out for every MIDI device, or the default camera.
    var device: String?
    /// Video and picture: path or filename of the media file.
    var file: String?
    /// Audio In: which stereo pair of the source to listen to, 0 (channels 1–2) when left out.
    var channelPair: Int?
    /// MIDI: learned controls, which are its outputs (`cc-31-7`, `note-11-1`, `pb-0-1`).
    var controls: [String]?
    var preset: String?
    var enabled: Bool?
    var params: [String: Float]?

    var isMIDI: Bool { type == "midi" }
    var isWebcam: Bool { type == "webcam" }
    var isVideo: Bool { type == "video" }
    var isPicture: Bool { type == "picture" }
    /// Chain key: `audio`, `midi.<id>`, `webcam.<id>`, `video.<id>` or `picture.<id>`.
    var deviceKey: String { isMIDI || isWebcam || isVideo || isPicture ? "\(type).\(id ?? type)" : type }
}

struct CameraSlot: Codable, Equatable {
    /// Camera tool: a `CameraRig` raw value (`orbit`, `static`, `fly`, `vertigo`, `cutter`, `lissajous`).
    var type: String
    /// Preset it was loaded from, for display.
    var preset: String?
    var params: [String: Float]?
}

struct LensSlot: Codable, Equatable {
    /// Lens tool: a shader in Shaders/lenses, without extension (`distortion`).
    var type: String
    /// Preset it was loaded from, for display.
    var preset: String?
    /// Knob values; unlisted knobs use the shader's defaults.
    var params: [String: Float]?
}

struct PaletteSlot: Codable, Equatable {
    /// Unique id within the scene; nil for the scene's first palette, which is plain `palette`.
    var id: String? = nil
    var preset: String?
    var colors: [String]
    /// The palette's inputs: red, green, blue, hue, saturation, brightness.
    var params: [String: Float]?

    /// Chain key, as used in mapping keys: `palette` or `palette.<id>`.
    var key: String { id.map { "palette.\($0)" } ?? "palette" }
}

struct GeneratorSlot: Codable, Identifiable, Equatable {
    /// Unique id within the scene; nil for the scene's first generator, which is plain `generator`.
    var id: String?
    /// Generator tool: a shader in a Shaders/generators category folder, without extension
    /// (`torus`, `wheel`). Its mesh and mesh knobs come from the shader.
    var type: String
    /// Preset it was loaded from, for display.
    var preset: String?
    /// Knob values; unlisted knobs use the shader's defaults.
    var params: [String: Float]?

    /// Chain key, as used in mapping targets: `generator` or `generator.<id>`.
    var key: String { id.map { "generator.\($0)" } ?? "generator" }
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
    /// A value output (`audio.kick`, `audio.pulse`, `mod.lfo.out`, `midi.midi.cc-31-7`, `camera.angle`)
    /// or a stream output (`webcam.<id>.video`, `audio.spectrum`, `palette.colors`, `palette.<id>.colors`).
    var source: String
    /// A knob (`generator.<param>`, `camera.<param>`, `post.<id>.<param>`, `mod.<id>.<param>`,
    /// `webcam.<id>.<param>`) for a value, or a stream input of the same kind
    /// (`generator.bgVideo`, `generator.spec`, `generator.pal`) for a stream.
    var target: String
    /// Value mappings: fraction of the knob's range added at full signal, 0...1.
    var amount: Float?
    /// Value mappings: pushes the knob down instead of up.
    var invert: Bool?
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
