import Metal

/// The kinds of IO. A value output (0...1, like `audio.kick`) maps onto knobs. The others are
/// streams a device produces, each mapped onto one input of the same kind.
/// - video: a picture, like a webcam's feed.
/// - spectrum: Audio In's 128 log-spaced bins, 30 Hz to 16 kHz, values 0...1.
/// - palette: a Palette's gradient, with its inputs applied.
/// - onsets: Audio In's onset strength, frame by frame, for the Clock's beat tracking.
/// - clock: Clock's tempo / beat sync stream, for syncing LFOs and modulators.
/// Video, spectrum and palette are textures a shader declares an input for; onsets go only
/// into the Clock's Audio input; clock sync goes into modulators. Nothing reaches a shader,
/// the Clock, or an LFO except through a mapping: no shared audio, clock or colors.
enum IOKind: String {
    case value, video, spectrum, palette, onsets, clock

    var isStream: Bool { self != .value }

    /// As written in messages: "video", "spectrum", "palette", "values", "clock".
    var noun: String { self == .value ? "values" : rawValue }

    /// SF Symbol for sockets and mappings.
    var icon: String {
        switch self {
        case .value: return "dial.medium"
        case .video: return "video"
        case .spectrum: return "waveform"
        case .palette: return "paintpalette"
        case .onsets: return "metronome"
        case .clock: return "clock"
        }
    }

    /// The shader declaration that makes an input of this kind: `// @video name Label`.
    /// Values, onsets and clock have none.
    var directive: String? { isStream && self != .onsets && self != .clock ? "// @\(rawValue) " : nil }
}

/// A stream a device produces: a webcam's video (`webcam.<id>.video`), Audio In's spectrum
/// (`audio.spectrum`) and onsets (`audio.onsets`), or the palette's gradient (`palette.colors`).
final class StreamOutput: Identifiable {
    let key: String
    let name: String
    /// The device it belongs to, for display.
    let device: String
    let kind: IOKind
    /// Video: written by the renderer each frame. Spectrum and palette textures change every
    /// frame, so the renderer supplies those when it binds them.
    let texture: MTLTexture?
    var id: String { key }
    var deviceKey: String { devicePath(key) }

    init(_ key: String, _ name: String, device: String, kind: IOKind = .video, texture: MTLTexture? = nil) {
        self.key = key; self.name = name; self.device = device; self.kind = kind; self.texture = texture
    }

    static let spectrumKey = "audio.spectrum"
    static let paletteKey = "palette.colors"
    static let onsetsKey = "audio.onsets"
    static let clockSyncKey = "clock.sync"

    static func spectrum() -> StreamOutput { StreamOutput(spectrumKey, "Spectrum", device: "Audio In", kind: .spectrum) }
    static func onsets() -> StreamOutput { StreamOutput(onsetsKey, "Onsets", device: "Audio In", kind: .onsets) }
    static func palette() -> StreamOutput { StreamOutput(paletteKey, "Colours", device: "Palette", kind: .palette) }
    static func clockSync() -> StreamOutput { StreamOutput(clockSyncKey, "Sync", device: "Clock", kind: .clock) }

    /// A stream output's kind from its key alone, for when its device isn't in the scene.
    static func kind(ofKey key: String) -> IOKind? {
        if key == spectrumKey { return .spectrum }
        if key == paletteKey { return .palette }
        if key == onsetsKey { return .onsets }
        if key == clockSyncKey { return .clock }
        if key.hasSuffix(".video") || (key.hasPrefix("webcam.") && key.hasSuffix(".depth")) { return .video }
        return nil
    }
}

/// A stream input a shader declares, such as the generator's `bgVideo`:
///   // @video bgVideo Background
///   // @spectrum spec Spectrum
///   // @palette pal Palette
/// Its target key is `<device>.<name>` (`generator.bgVideo`). Each takes one stream.
/// Inputs get texture slots in declaration order: generators from texture(0) (vertex and
/// fragment stage), effects from texture(2).
struct StreamInputDef: Hashable {
    let name: String
    let label: String
    let kind: IOKind

    static func parse(shaderSource: String) -> [StreamInputDef] {
        let kinds: [IOKind] = [.video, .spectrum, .palette]
        var defs: [StreamInputDef] = []
        for raw in shaderSource.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let kind = kinds.first(where: { line.hasPrefix($0.directive!) }) else { continue }
            let parts = line.dropFirst(kind.directive!.count).split(separator: " ", maxSplits: 1).map(String.init)
            guard let name = parts.first, name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  !defs.contains(where: { $0.name == name }) else { continue }
            defs.append(StreamInputDef(name: name, label: parts.count > 1 ? parts[1] : humanize(name), kind: kind))
        }
        return defs
    }
}

/// A stream input in the scene, for the UI: `generator.bgVideo`, "Background", video.
struct StreamInput: Identifiable, Hashable {
    /// The Clock's Audio input, which takes Audio In's Onsets to follow the beat.
    static let clockAudioKey = "clock.audio"

    let key: String
    let label: String
    let kind: IOKind
    var id: String { key }
    var deviceKey: String { devicePath(key) }
}
