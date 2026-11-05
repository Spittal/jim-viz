import AppKit
import Metal
import QuartzCore
import Observation
import simd

// MARK: - Runtime scene objects (built on main, read by the render thread)

final class GeneratorRuntime: Identifiable {
    let id: String
    let key: String
    let type: String
    let preset: String?
    let label: String?
    let shape: MeshShape
    let detail: Int
    let bank: ParamBank
    let meshPipeline: MTLRenderPipelineState
    let backgroundPipeline: MTLRenderPipelineState
    var vertexBuffer: MTLBuffer
    var vertexCount: Int
    /// Declared with `// @video`, `// @spectrum`, `// @palette`; bound from texture(0) up.
    let inputs: [StreamInputDef]

    var planeWidth: Float
    var planeHeight: Float
    var planeCols: Int
    var planeRows: Int

    init(id: String = "generator", key: String = "generator", type: String, preset: String? = nil, label: String? = nil,
         shape: MeshShape, detail: Int, bank: ParamBank,
         meshPipeline: MTLRenderPipelineState, backgroundPipeline: MTLRenderPipelineState,
         vertexBuffer: MTLBuffer, vertexCount: Int, inputs: [StreamInputDef],
         planeWidth: Float = 10, planeHeight: Float = 10) {
        self.id = id; self.key = key; self.type = type; self.preset = preset; self.label = label
        self.shape = shape; self.detail = detail; self.bank = bank
        self.inputs = inputs
        self.meshPipeline = meshPipeline; self.backgroundPipeline = backgroundPipeline
        self.vertexBuffer = vertexBuffer; self.vertexCount = vertexCount
        self.planeWidth = planeWidth
        self.planeHeight = planeHeight
        let (cols, rows) = MeshBuilder.planeDivisions(detail: detail, width: planeWidth, height: planeHeight)
        self.planeCols = cols
        self.planeRows = rows
    }

    func updatePlaneMeshIfNeeded(renderer: Renderer) {
        guard shape == .plane else { return }
        let w = bank["width"]?.liveBase ?? 10
        let h = bank["height"]?.liveBase ?? 10
        let (cols, rows) = MeshBuilder.planeDivisions(detail: detail, width: w, height: h)
        if cols == planeCols && rows == planeRows { return }
        planeCols = cols
        planeRows = rows
        planeWidth = w
        planeHeight = h
        let verts = MeshBuilder.build(.plane, detail: detail, width: w, height: h)
        let byteCount = MemoryLayout<MeshVertex>.stride * verts.count
        if vertexBuffer.length >= byteCount {
            vertexBuffer.contents().copyMemory(from: verts, byteCount: byteCount)
        } else {
            let capacity = max(Int(Double(byteCount) * 1.25), 65536)
            guard let newBuf = renderer.device.makeBuffer(length: capacity, options: .storageModeShared) else { return }
            newBuf.contents().copyMemory(from: verts, byteCount: byteCount)
            vertexBuffer = newBuf
        }
        vertexCount = verts.count
    }
}

@Observable
final class EffectRuntime: Identifiable {
    let id: String
    let effect: String
    /// Name of the preset it was loaded from, if any.
    let presetLabel: String?
    var enabled: Bool
    let bank: ParamBank
    @ObservationIgnored let pipeline: MTLRenderPipelineState?
    /// When true, texture(1) is this effect's own previous output instead of the final frame.
    @ObservationIgnored let selfHistory: Bool
    /// Declared with `// @video`, `// @spectrum`, `// @palette`; bound from texture(2) up.
    @ObservationIgnored let inputs: [StreamInputDef]
    /// This effect's own output and last frame's, for `selfHistory`. Made on main when the
    /// effect is built and carried over when the chain is edited, so the render thread never
    /// allocates them, and two scenes in a crossfade never share one.
    @ObservationIgnored let history: HistoryPair?

    init(id: String, effect: String, presetLabel: String?, enabled: Bool, bank: ParamBank,
         pipeline: MTLRenderPipelineState?, selfHistory: Bool, inputs: [StreamInputDef] = [], history: HistoryPair? = nil) {
        self.inputs = inputs
        self.history = selfHistory ? history : nil
        self.id = id; self.effect = effect; self.presetLabel = presetLabel; self.enabled = enabled; self.bank = bank
        self.pipeline = pipeline; self.selfHistory = selfHistory
    }
}

/// Two textures a self-history effect swaps each frame. Render thread only, after init.
final class HistoryPair {
    private(set) var current: MTLTexture
    private(set) var previous: MTLTexture

    init(_ a: MTLTexture, _ b: MTLTexture) { current = a; previous = b }

    func swap() { Swift.swap(&current, &previous) }
}

/// A palette's gradient on the GPU: a few 256×1 textures rotated on change, so the CPU never
/// rewrites one the GPU may still be reading. Render thread only, after init.
final class PaletteTextures {
    let textures: [MTLTexture]
    private(set) var index = 0
    /// What the current texture holds: the colours' version and the palette's input values.
    var writtenVersion = -1
    var writtenInputs = [Float](repeating: .nan, count: PaletteParams.defs.count)

    init(_ textures: [MTLTexture]) { self.textures = textures }

    var current: MTLTexture { textures[index] }

    /// Moves to the next texture, to be written.
    func advance() -> MTLTexture {
        index = (index + 1) % textures.count
        return textures[index]
    }
}

/// Scene colors. The UI edits `colors`; the render thread reads a locked copy.
/// `bank` holds the palette's inputs (RGB, hue, saturation, brightness), applied each frame.
@Observable
final class PaletteModel {
    private(set) var colors: [SIMD3<Float>]
    let bank: ParamBank
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var renderCopy: [SIMD3<Float>]
    @ObservationIgnored private var version: Int
    /// Versions are unique across all palettes, so switching scenes always re-uploads.
    private static var counter = 0

    /// The gradient's textures. Carried over when the scene is rebuilt.
    @ObservationIgnored let gpu: PaletteTextures

    init(_ colors: [SIMD3<Float>], bank: ParamBank, gpu: PaletteTextures) {
        self.bank = bank
        self.gpu = gpu
        let c = colors.isEmpty ? [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1)] : colors
        self.colors = c
        renderCopy = c
        Self.counter += 1
        version = Self.counter
    }

    func set(_ index: Int, _ color: SIMD3<Float>) {
        guard colors.indices.contains(index) else { return }
        colors[index] = color
        publish()
    }

    func replace(_ newColors: [SIMD3<Float>]) {
        guard newColors.count >= 2 else { return }
        colors = newColors
        publish()
    }

    private func publish() {
        Self.counter += 1
        lock.lock(); renderCopy = colors; version = Self.counter; lock.unlock()
    }

    func snapshot() -> (Int, [SIMD3<Float>]) {
        lock.lock(); defer { lock.unlock() }
        return (version, renderCopy)
    }
}

/// A device in the scene's Inputs section.
enum InputDevice: Identifiable {
    case audio(AudioInRuntime), clock(ClockRuntime), midi(MIDIInputRuntime), webcam(WebcamRuntime)

    /// Chain key, as used for selection and in mapping keys.
    var id: String {
        switch self {
        case .audio: return "audio"
        case .clock: return "clock"
        case .midi(let m): return m.key
        case .webcam(let w): return w.key
        }
    }
}

final class RenderScene {
    let name: String
    let generators: [GeneratorRuntime]
    var generator: GeneratorRuntime? { generators.first }
    /// Preset ids each device was loaded from, and display labels, for the UI.
    var generatorPreset: String? { generators.first?.preset }
    var generatorLabel: String? { generators.first?.label }
    /// Audio In, Clock, MIDI and webcam inputs, in chain order.
    let inputs: [InputDevice]
    let audioIn: AudioInRuntime?
    let clock: ClockRuntime?
    let modulators: [ModulatorRuntime]
    let midiInputs: [MIDIInputRuntime]
    let webcams: [WebcamRuntime]
    /// Every stream output (video, spectrum, palette) and stream input in the chain, in chain order.
    let streamOutputs: [StreamOutput]
    let streamInputs: [StreamInput]
    /// Which stream feeds each stream input, by input key (`generator.texVideo`). Active routes only.
    let streamBindings: [String: StreamOutput]
    let camera: ParamBank?
    let cameraMotion: CameraMotion?
    let cameraPreset: String?
    let cameraLabel: String?
    let effects: [EffectRuntime]
    let palette: PaletteModel?
    let palettePreset: String?
    let paletteLabel: String?
    /// Every output in the chain, in chain order.
    let outputs: [OutputSignal]
    let mappings: [MappingRuntime]
    let banks: [ParamBank]
    /// Knob banks by target prefix: `generator`, `camera`, `post.<id>`, `mod.<id>`.
    let banksByPath: [String: ParamBank]
    var hasAudioInput: Bool { audioIn != nil }
    var hasClock: Bool { clock != nil }
    /// Every device's chain key, left to right: inputs, `camera`, `palette`, generators, `post.<id>`.
    let deviceKeys: [String]
    /// The stream feeding each generator's inputs, keyed by generator key.
    let generatorSources: [String: [StreamOutput?]]
    var generatorSourcesList: [StreamOutput?] { generators.first.flatMap { generatorSources[$0.key] } ?? [] }
    let effectSources: [String: [StreamOutput?]]
    /// True when something reads the palette's colours, so its gradient is worth updating.
    let usesPalette: Bool
    /// True when Audio In's Audio Out is mapped into the Clock's Audio input.
    var clockHearsAudio: Bool { clock?.hearsAudio == true }
    /// The MIDI input learning controls, if any.
    var learningMIDI: MIDIInputRuntime? { midiInputs.first(where: \.isLearning) }

    init(name: String, generators: [GeneratorRuntime],
         inputs: [InputDevice], modulators: [ModulatorRuntime],
         streamOutputs: [StreamOutput], streamBindings: [String: StreamOutput],
         camera: ParamBank?, cameraMotion: CameraMotion?, cameraPreset: String?, cameraLabel: String?,
         effects: [EffectRuntime], palettePreset: String?, palette: PaletteModel?, paletteLabel: String?,
         outputs: [OutputSignal], mappings: [MappingRuntime], banksByPath: [String: ParamBank]) {
        self.name = name; self.generators = generators
        self.inputs = inputs
        self.modulators = modulators
        audioIn = inputs.lazy.compactMap { if case .audio(let a) = $0 { return a } else { return nil } }.first
        clock = inputs.lazy.compactMap { if case .clock(let c) = $0 { return c } else { return nil } }.first
        midiInputs = inputs.compactMap { if case .midi(let m) = $0 { return m } else { return nil } }
        webcams = inputs.compactMap { if case .webcam(let w) = $0 { return w } else { return nil } }
        self.streamOutputs = streamOutputs
        self.streamBindings = streamBindings
        streamInputs = (clock != nil ? [StreamInput(key: StreamInput.clockAudioKey, label: "Audio", kind: .audio)] : [])
            + modulators.map { StreamInput(key: "mod.\($0.id).sync", label: "Sync", kind: .clock) }
            + generators.flatMap { gen in gen.inputs.map { StreamInput(key: "\(gen.key).\($0.name)", label: $0.label, kind: $0.kind) } }
            + effects.flatMap { fx in fx.inputs.map { StreamInput(key: "post.\(fx.id).\($0.name)", label: $0.label, kind: $0.kind) } }
        generatorSources = Dictionary(generators.map { gen in (gen.key, gen.inputs.map { streamBindings["\(gen.key).\($0.name)"] }) },
                                      uniquingKeysWith: { a, _ in a })
        effectSources = Dictionary(effects.map { fx in (fx.id, fx.inputs.map { streamBindings["post.\(fx.id).\($0.name)"] }) },
                                   uniquingKeysWith: { a, _ in a })
        usesPalette = palette != nil && streamBindings.values.contains { $0.kind == .palette }
        self.camera = camera; self.cameraMotion = cameraMotion; self.cameraPreset = cameraPreset; self.cameraLabel = cameraLabel
        self.effects = effects; self.palette = palette; self.palettePreset = palettePreset; self.paletteLabel = paletteLabel
        self.outputs = outputs; self.mappings = mappings; self.banksByPath = banksByPath
        deviceKeys = inputs.map(\.id) + modulators.map { "mod.\($0.id)" } + (camera != nil ? ["camera"] : []) + (palette != nil ? ["palette"] : []) + generators.map(\.key) + effects.map { "post.\($0.id)" }
        banks = [audioIn?.bank, clock?.bank].compactMap { $0 } + (palette.map { [$0.bank] } ?? []) + webcams.map(\.bank) + modulators.map(\.bank) + generators.map(\.bank) + (camera.map { [$0] } ?? []) + effects.map(\.bank)
    }

    convenience init(name: String, generatorPreset: String?, generatorLabel: String?, generator: GeneratorRuntime?,
                     inputs: [InputDevice], modulators: [ModulatorRuntime],
                     streamOutputs: [StreamOutput], streamBindings: [String: StreamOutput],
                     camera: ParamBank?, cameraMotion: CameraMotion?, cameraPreset: String?, cameraLabel: String?,
                     effects: [EffectRuntime], palettePreset: String?, palette: PaletteModel?, paletteLabel: String?,
                     outputs: [OutputSignal], mappings: [MappingRuntime], banksByPath: [String: ParamBank]) {
        self.init(name: name, generators: generator.map { [$0] } ?? [], inputs: inputs, modulators: modulators,
                  streamOutputs: streamOutputs, streamBindings: streamBindings, camera: camera, cameraMotion: cameraMotion,
                  cameraPreset: cameraPreset, cameraLabel: cameraLabel, effects: effects, palettePreset: palettePreset,
                  palette: palette, paletteLabel: paletteLabel, outputs: outputs, mappings: mappings, banksByPath: banksByPath)
    }

    /// Starts one MIDI input learning controls, stopping any other, or stops learning (nil).
    func learnMIDI(_ key: String?) {
        for m in midiInputs where m.isLearning != (m.key == key) { m.isLearning = m.key == key }
    }

    /// Render thread, once per frame: runs its inputs (Audio In analyses, then the Clock
    /// advances, hearing that analysis if mapped), updates every output, then applies mappings
    /// to every knob. Nothing here is shared with another scene.
    func modulate(_ f: SignalFrame) {
        audioIn?.process(dt: f.dt)
        clock?.advance(f)
        for o in outputs { o.update(f) }
        for bank in banks { for p in bank.params { p.modAccum = 0 } }
        for m in mappings { m.modulate(f.dt) }
        for bank in banks {
            for p in bank.params { p.live = p.def.clamp(p.liveBase + p.modAccum) }
        }
    }
}

// MARK: - Renderer

/// Owns GPU resources and encodes one frame: scene pass, post chain, present.
final class Renderer {
    static let sampleCount = 4
    static let workFormat: MTLPixelFormat = .rgba16Float
    static let drawableFormat: MTLPixelFormat = .bgra8Unorm

    let device: MTLDevice
    let queue: MTLCommandQueue
    private(set) var outputSize = MTLSize(width: 1920, height: 1080, depth: 1)

    private var msaaColor: MTLTexture!
    private var msaaDepth: MTLTexture!
    /// The generator's resolved picture, which the post chain starts from.
    private var sceneTex: MTLTexture!
    private var ping: MTLTexture!
    private var pong: MTLTexture!
    /// Each scene's finished picture during a crossfade, blended into `history`.
    private var transitionFrom: MTLTexture!
    private var transitionTo: MTLTexture!
    /// Final output of the previous frame. Sampled by feedback effects and presented.
    private(set) var history: MTLTexture!

    /// Scratch for writing a palette gradient, so updating one allocates nothing.
    private var gradientPixels = [Float16](repeating: 1, count: 256 * 4)
    private var gradientColors: [SIMD3<Float>] = []
    private var presentPipeline: MTLRenderPipelineState!
    /// Bound to unconnected video and spectrum inputs.
    private var blackTexture: MTLTexture!
    /// Bound to unconnected palette inputs: a grey ramp, black to white.
    private var greyRamp: MTLTexture!
    /// Size of every processed video texture.
    static let videoSize = (width: 1280, height: 720)
    /// Webcam depth outputs: plenty for displacing a mesh, and cheap to smooth every frame.
    static let depthSize = (width: 384, height: 216)
    private var transitionPipeline: MTLRenderPipelineState!
    private var webcamBgPipeline: MTLRenderPipelineState!

    private func makeWebcamBgPipeline() {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct FXOut { float4 position [[position]]; float2 uv; };
        vertex FXOut bg_vertex(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            FXOut o; o.position = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); return o;
        }
        fragment float4 bg_fragment(FXOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant float& amount [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float3 c = tex.sample(s, in.uv).rgb;
            return float4(c * amount, amount);
        }
        """
        let lib = try! device.makeLibrary(source: src, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "bg_vertex")
        d.fragmentFunction = lib.makeFunction(name: "bg_fragment")
        d.colorAttachments[0].pixelFormat = Self.workFormat
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].rgbBlendOperation = .add
        d.colorAttachments[0].sourceRGBBlendFactor = .one
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].alphaBlendOperation = .add
        d.colorAttachments[0].sourceAlphaBlendFactor = .zero
        d.colorAttachments[0].destinationAlphaBlendFactor = .zero
        d.depthAttachmentPixelFormat = .depth32Float
        d.rasterSampleCount = Self.sampleCount
        webcamBgPipeline = try! device.makeRenderPipelineState(descriptor: d)
    }
    private let depthOn: MTLDepthStencilState
    private let depthOff: MTLDepthStencilState

    init(device: MTLDevice) {
        self.device = device
        queue = device.makeCommandQueue()!
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 256, height: 1, mipmapped: false)
        pd.usage = .shaderRead
        gradientColors.reserveCapacity(64)
        let on = MTLDepthStencilDescriptor()
        on.depthCompareFunction = .less
        on.isDepthWriteEnabled = true
        depthOn = device.makeDepthStencilState(descriptor: on)!
        let off = MTLDepthStencilDescriptor()
        off.depthCompareFunction = .always
        off.isDepthWriteEnabled = false
        depthOff = device.makeDepthStencilState(descriptor: off)!
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        bd.usage = .shaderRead
        blackTexture = device.makeTexture(descriptor: bd)!
        blackTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](arrayLiteral: 0, 0, 0, 255), bytesPerRow: 4)
        greyRamp = device.makeTexture(descriptor: pd)!
        writeGradient([SIMD3(0, 0, 0), SIMD3(1, 1, 1)], into: greyRamp)
        makeTargets()
        makePresentPipeline()
        makeTransitionPipeline()
        makeWebcamBgPipeline()
    }

    /// Textures for an Audio In's spectrum, silent to start. Call on main, when it is built.
    func makeSpectrumTextures() -> SpectrumTextures {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: AudioAnalyzer.spectrumBins,
                                                         height: 1, mipmapped: false)
        d.usage = .shaderRead
        let zeros = [Float](repeating: 0, count: AudioAnalyzer.spectrumBins)
        let textures = (0..<4).map { _ in
            let t = device.makeTexture(descriptor: d)!
            zeros.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, zeros.count, 1), mipmapLevel: 0,
                                              withBytes: $0.baseAddress!, bytesPerRow: zeros.count * 4) }
            return t
        }
        return SpectrumTextures(textures)
    }

    private func makeTargets() {
        let w = outputSize.width, h = outputSize.height
        func tex(_ fmt: MTLPixelFormat, samples: Int = 1, usage: MTLTextureUsage, memoryless: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.usage = usage
            if samples > 1 { d.textureType = .type2DMultisample; d.sampleCount = samples }
            d.storageMode = memoryless && device.supportsFamily(.apple7) ? .memoryless : .private
            return device.makeTexture(descriptor: d)!
        }
        msaaColor = tex(Self.workFormat, samples: Self.sampleCount, usage: .renderTarget, memoryless: true)
        msaaDepth = tex(.depth32Float, samples: Self.sampleCount, usage: .renderTarget, memoryless: true)
        sceneTex = tex(Self.workFormat, usage: [.renderTarget, .shaderRead])
        transitionFrom = tex(Self.workFormat, usage: [.renderTarget, .shaderRead])
        transitionTo = tex(Self.workFormat, usage: [.renderTarget, .shaderRead])
        ping = tex(Self.workFormat, usage: [.renderTarget, .shaderRead])
        pong = tex(Self.workFormat, usage: [.renderTarget, .shaderRead])
        history = tex(Self.workFormat, usage: [.renderTarget, .shaderRead])
    }

    /// Textures for a self-history effect. Call on main, when the effect is built.
    func makeHistoryPair() -> HistoryPair { HistoryPair(makeWorkTexture(), makeWorkTexture()) }

    /// Textures for a palette's gradient. Call on main, when the scene is built. Four is more
    /// than the frames in flight, so a texture is never rewritten while the GPU reads it.
    func makePaletteTextures() -> PaletteTextures {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 256, height: 1, mipmapped: false)
        d.usage = .shaderRead
        return PaletteTextures((0..<4).map { _ in device.makeTexture(descriptor: d)! })
    }

    private func makeWorkTexture() -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.workFormat, width: outputSize.width,
                                                         height: outputSize.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    private func makePresentPipeline() {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct PV { float4 pos [[position]]; float2 uv; };
        vertex PV present_vertex(uint vid [[vertex_id]], constant float2& scale [[buffer(0)]]) {
            float2 p = float2(vid & 1, vid >> 1);
            PV o; o.pos = float4((p * 2 - 1) * scale, 0, 1); o.uv = float2(p.x, 1 - p.y); return o;
        }
        fragment float4 present_fragment(PV in [[stage_in]], texture2d<float> src [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return float4(saturate(src.sample(s, in.uv).rgb), 1);
        }
        """
        let lib = try! device.makeLibrary(source: src, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "present_vertex")
        d.fragmentFunction = lib.makeFunction(name: "present_fragment")
        d.colorAttachments[0].pixelFormat = Self.drawableFormat
        presentPipeline = try! device.makeRenderPipelineState(descriptor: d)
    }

    private func makeTransitionPipeline() {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct FXOut { float4 position [[position]]; float2 uv; };
        vertex FXOut transition_vertex(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            FXOut o; o.position = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); return o;
        }
        fragment float4 transition_fragment(FXOut in [[stage_in]],
                                            texture2d<float> fromTex [[texture(0)]],
                                            texture2d<float> toTex [[texture(1)]],
                                            constant float& progress [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return mix(fromTex.sample(s, in.uv), toTex.sample(s, in.uv), saturate(progress));
        }
        """
        let lib = try! device.makeLibrary(source: src, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "transition_vertex")
        d.fragmentFunction = lib.makeFunction(name: "transition_fragment")
        d.colorAttachments[0].pixelFormat = Self.workFormat
        transitionPipeline = try! device.makeRenderPipelineState(descriptor: d)
    }

    // MARK: Pipeline factories (called on main when shaders compile)

    func makeGeneratorPipelines(_ shader: CompiledShader) throws -> (mesh: MTLRenderPipelineState, background: MTLRenderPipelineState) {
        let lib = shader.library
        guard let v = lib.makeFunction(name: "gen_vertex"), let f = lib.makeFunction(name: "gen_fragment") else {
            throw ShaderError(file: shader.url.lastPathComponent, message: "needs gen_vertex and gen_fragment functions")
        }
        guard let bv = lib.makeFunction(name: "fx_vertex"), let bf = lib.makeFunction(name: "gen_background") else {
            throw ShaderError(file: shader.url.lastPathComponent, message: "needs a gen_background function")
        }
        func pipe(_ vf: MTLFunction, _ ff: MTLFunction, blend: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            d.colorAttachments[0].pixelFormat = Self.workFormat
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = Self.sampleCount
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].rgbBlendOperation = .add
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .one
                d.colorAttachments[0].alphaBlendOperation = .add
                d.colorAttachments[0].sourceAlphaBlendFactor = .zero
                d.colorAttachments[0].destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        do {
            return (try pipe(v, f, blend: false), try pipe(bv, bf, blend: true))
        } catch {
            throw ShaderError(file: shader.url.lastPathComponent, message: ShaderCompiler.summarize(error))
        }
    }

    func makeEffectPipeline(_ shader: CompiledShader) throws -> MTLRenderPipelineState {
        guard let v = shader.library.makeFunction(name: "fx_vertex"),
              let f = shader.library.makeFunction(name: "effect") else {
            throw ShaderError(file: shader.url.lastPathComponent, message: "needs a fragment function named effect")
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = Self.workFormat
        do {
            return try device.makeRenderPipelineState(descriptor: d)
        } catch {
            throw ShaderError(file: shader.url.lastPathComponent, message: ShaderCompiler.summarize(error))
        }
    }

    /// The webcam processing pass, from `Shaders/inputs/webcam.metal`.
    func makeWebcamPipeline(_ shader: CompiledShader) throws -> MTLRenderPipelineState {
        guard let v = shader.library.makeFunction(name: "fx_vertex"),
              let f = shader.library.makeFunction(name: "webcam") else {
            throw ShaderError(file: shader.url.lastPathComponent, message: "needs a fragment function named webcam")
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = Self.workFormat
        do {
            return try device.makeRenderPipelineState(descriptor: d)
        } catch {
            throw ShaderError(file: shader.url.lastPathComponent, message: ShaderCompiler.summarize(error))
        }
    }

    /// The webcam depth pass, `webcam_depth` in `Shaders/inputs/webcam.metal`.
    func makeDepthPipeline(_ shader: CompiledShader) throws -> MTLRenderPipelineState {
        guard let v = shader.library.makeFunction(name: "fx_vertex"),
              let f = shader.library.makeFunction(name: "webcam_depth") else {
            throw ShaderError(file: shader.url.lastPathComponent, message: "needs a fragment function named webcam_depth")
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = Self.workFormat
        do {
            return try device.makeRenderPipelineState(descriptor: d)
        } catch {
            throw ShaderError(file: shader.url.lastPathComponent, message: ShaderCompiler.summarize(error))
        }
    }

    func makeDepthTexture() -> MTLTexture {
        makeVideoTexture(width: Self.depthSize.width, height: Self.depthSize.height)
    }

    func makeVideoTexture(width: Int = Renderer.videoSize.width, height: Int = Renderer.videoSize.height) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.workFormat, width: width,
                                                         height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    /// Processes each webcam's latest frame into its video output. Before the first frame
    /// (or without a camera) the output is black.
    private func encodeWebcams(_ cmd: MTLCommandBuffer, _ scene: RenderScene, _ f: inout FrameUniforms) {
        for cam in scene.webcams {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = cam.processed
            pass.colorAttachments[0].storeAction = .store
            let frame = cam.feed.latest()
            guard let frame, let pipeline = cam.pipeline else {
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
                continue
            }
            pass.colorAttachments[0].loadAction = .dontCare
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { continue }
            enc.label = cam.key
            var vf = f
            vf.resolution = SIMD2(Float(Self.videoSize.width), Float(Self.videoSize.height))
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(frame.texture, index: 0)
            enc.setFragmentBytes(&vf, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            cam.bank.withPacked { enc.setFragmentBytes($0, length: $1, index: 1) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            // Keep the camera's pixel buffer alive until the GPU has read it.
            if let owner = frame.owner { cmd.addCompletedHandler { _ in withExtendedLifetime(owner) {} } }
        }
        for cam in scene.webcams where cam.depthMapped { encodeDepth(cmd, cam, f) }
    }

    /// Draws a webcam's Depth output from the estimator's latest depth, framed like its video
    /// and eased toward it from last frame's. Black (all far) until the first depth arrives.
    private func encodeDepth(_ cmd: MTLCommandBuffer, _ cam: WebcamRuntime, _ f: FrameUniforms) {
        let target = cam.depth
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        guard let raw = cam.feed.depth.latest()?.texture, let pipeline = cam.depthPipeline else {
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            return
        }
        pass.colorAttachments[0].loadAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "\(cam.key).depth"
        var vf = f
        vf.resolution = SIMD2(Float(target.width), Float(target.height))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(raw, index: 0)
        enc.setFragmentTexture(cam.depthHistory, index: 1)
        enc.setFragmentBytes(&vf, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        cam.bank.withPacked { enc.setFragmentBytes($0, length: $1, index: 1) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: target, to: cam.depthHistory)
            blit.endEncoding()
        }
    }

    /// Binds a shader's inputs from texture `first` up and returns the connected-inputs bitmask
    /// for `Frame.inputs` (bit n for texture(n)). Unconnected video and spectrum get black, an
    /// unconnected palette the grey ramp. Generators also get them in the vertex stage, at the
    /// same indices, so the spectrum or a video (like a webcam's depth) can move the mesh.
    private func bindInputs(_ enc: MTLRenderCommandEncoder, _ inputs: [StreamInputDef], sources: [StreamOutput?],
                            from first: Int, vertex: Bool = false) -> Float {
        var mask = 0
        for (i, input) in inputs.enumerated() {
            let source = i < sources.count ? sources[i] : nil
            let tex: MTLTexture
            if let t = source?.currentTexture { tex = t }
            else { tex = input.kind == .palette ? greyRamp : blackTexture }
            if source != nil { mask |= 1 << (first + i) }
            enc.setFragmentTexture(tex, index: first + i)
            if vertex { enc.setVertexTexture(tex, index: first + i) }
        }
        return Float(mask)
    }

    func makeMesh(_ shape: MeshShape, detail: Int, width: Float = 10, height: Float = 10) -> (MTLBuffer, Int) {
        let verts = MeshBuilder.build(shape, detail: detail, width: width, height: height)
        let byteCount = MemoryLayout<MeshVertex>.stride * verts.count
        let capacity = shape == .plane ? max(Int(Double(byteCount) * 1.25), 65536) : byteCount
        let buf = device.makeBuffer(length: capacity, options: .storageModeShared)!
        buf.contents().copyMemory(from: verts, byteCount: byteCount)
        return (buf, verts.count)
    }

    // MARK: Frame encoding

    func encode(_ cmd: MTLCommandBuffer, scene: RenderScene, frame f: inout FrameUniforms) {
        encodeScene(cmd, scene: scene, frame: &f, into: history)
    }

    /// Draws a scene and its post chain into `target`, which must not be `sceneTex`, `ping` or
    /// `pong`: the next scene drawn in the same frame reuses those.
    func encodeScene(_ cmd: MTLCommandBuffer, scene: RenderScene, frame f: inout FrameUniforms, into target: MTLTexture) {
        encodeWebcams(cmd, scene, &f)
        f.resolution = SIMD2(Float(outputSize.width), Float(outputSize.height))
        if scene.usesPalette, let pal = scene.palette { updatePalette(pal) }
        var cam = cameraUniforms(scene.camera, scene.cameraMotion, frame: f)

        // Scene pass.
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = msaaColor
        rp.colorAttachments[0].resolveTexture = sceneTex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .multisampleResolve
        rp.depthAttachment.texture = msaaDepth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1
        rp.depthAttachment.storeAction = .dontCare

        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.label = "scene"

            // 1. Draw webcam backgrounds in chain order for webcams with bg > 0.
            for cam in scene.webcams {
                let bg = cam.bank["bg"]?.live ?? 0
                if bg > 0 {
                    enc.setRenderPipelineState(webcamBgPipeline)
                    enc.setDepthStencilState(depthOff)
                    enc.setFragmentTexture(cam.processed, index: 0)
                    var amount = bg
                    enc.setFragmentBytes(&amount, length: MemoryLayout<Float>.size, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
            }

            // 2. Draw generator backgrounds in chain order (behind all meshes).
            for gen in scene.generators where (gen.bank["bgGlow"]?.live ?? 0) > 0 {
                let sources = scene.generatorSources[gen.key] ?? []
                f.inputs = bindInputs(enc, gen.inputs, sources: sources, from: 0, vertex: true)
                enc.setFragmentBytes(&f, length: MemoryLayout<FrameUniforms>.stride, index: 0)
                gen.bank.withPacked {
                    enc.setFragmentBytes($0, length: $1, index: 1)
                    enc.setVertexBytes($0, length: $1, index: 2)
                }
                enc.setFragmentBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 2)
                enc.setRenderPipelineState(gen.backgroundPipeline)
                enc.setDepthStencilState(depthOff)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            // 3. Render generator meshes in chain order on the same stage.
            for gen in scene.generators {
                if gen.shape == .plane {
                    gen.updatePlaneMeshIfNeeded(renderer: self)
                }
                let sources = scene.generatorSources[gen.key] ?? []
                f.inputs = bindInputs(enc, gen.inputs, sources: sources, from: 0, vertex: true)
                enc.setFragmentBytes(&f, length: MemoryLayout<FrameUniforms>.stride, index: 0)
                gen.bank.withPacked {
                    enc.setFragmentBytes($0, length: $1, index: 1)
                    enc.setVertexBytes($0, length: $1, index: 2)
                }
                enc.setFragmentBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 2)

                enc.setRenderPipelineState(gen.meshPipeline)
                enc.setDepthStencilState(depthOn)
                enc.setCullMode(.none)
                enc.setVertexBuffer(gen.vertexBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&f, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                enc.setVertexBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 3)
                let instances = max(1, Int(gen.bank["instances"]?.live ?? 1))
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gen.vertexCount, instanceCount: instances)
            }
            enc.endEncoding()
        }

        // Post chain, ping-ponging between two targets.
        var src: MTLTexture = sceneTex
        for fx in scene.effects where fx.enabled {
            guard let pipeline = fx.pipeline else { continue }
            var dst: MTLTexture = src === ping ? pong! : ping!
            var historyTex: MTLTexture = history
            if let pair = fx.history {
                pair.swap()
                dst = pair.current
                historyTex = pair.previous
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = dst
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { continue }
            enc.label = fx.id
            var ff = f
            ff.inputs = bindInputs(enc, fx.inputs, sources: scene.effectSources[fx.id] ?? [], from: 2)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentTexture(historyTex, index: 1)
            enc.setFragmentBytes(&ff, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            fx.bank.withPacked { enc.setFragmentBytes($0, length: $1, index: 1) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            src = dst
        }

        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: src, to: target)
            blit.endEncoding()
        }
    }

    /// Draws both scenes, each into its own texture, and blends them into `history`.
    func encodeTransition(
        _ cmd: MTLCommandBuffer,
        from fromScene: RenderScene,
        to toScene: RenderScene,
        progress: Float,
        frame f: inout FrameUniforms
    ) {
        encodeScene(cmd, scene: fromScene, frame: &f, into: transitionFrom)
        encodeScene(cmd, scene: toScene, frame: &f, into: transitionTo)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = history
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "crossfade"

        var p = progress
        enc.setRenderPipelineState(transitionPipeline)
        enc.setFragmentTexture(transitionFrom, index: 0)
        enc.setFragmentTexture(transitionTo, index: 1)
        enc.setFragmentBytes(&p, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Draws the finished frame into a window's drawable, letterboxed to 16:9.
    func present(_ cmd: MTLCommandBuffer, into target: MTLTexture) {
        present(cmd, history, into: target)
    }

    /// Draws a texture into a drawable, letterboxed to 16:9.
    func present(_ cmd: MTLCommandBuffer, _ source: MTLTexture, into target: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let srcAspect = Float(outputSize.width) / Float(outputSize.height)
        let dstAspect = Float(target.width) / Float(max(target.height, 1))
        var scale = dstAspect > srcAspect ? SIMD2<Float>(srcAspect / dstAspect, 1) : SIMD2<Float>(1, dstAspect / srcAspect)
        enc.setRenderPipelineState(presentPipeline)
        enc.setVertexBytes(&scale, length: 8, index: 0)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func cameraUniforms(_ c: ParamBank?, _ motion: CameraMotion?, frame f: FrameUniforms) -> CameraUniforms {
        guard let c, let motion else {
            return CameraUniforms(viewProj: matrix_identity_float4x4, position: SIMD4(0, 0, 0, 1))
        }
        let pose = motion.advance(c, frame: f)
        // Roll turns the view about its own axis, so it reads the same from every direction.
        let forward = simd_normalize(pose.target - pose.eye)
        let up: SIMD3<Float> = abs(forward.y) > 0.999 ? SIMD3(0, 0, -1) : SIMD3(0, 1, 0)
        let view = simd_float4x4.rotationZ(pose.roll * .pi / 180) * simd_float4x4.lookAt(eye: pose.eye, target: pose.target, up: up)
        let proj = simd_float4x4.perspective(fovY: pose.fov * .pi / 180,
                                             aspect: f.resolution.x / f.resolution.y, near: 0.05, far: 300)
        return CameraUniforms(viewProj: proj * view, position: SIMD4(pose.eye, 1))
    }

    /// Writes the 256-step gradient, with the palette's inputs applied, into the palette's next
    /// texture, when its colours or inputs have changed since the last write.
    private func updatePalette(_ palette: PaletteModel) {
        let (version, base) = palette.snapshot()
        guard base.count >= 2 else { return }
        let gpu = palette.gpu
        var changed = version != gpu.writtenVersion
        for (i, p) in palette.bank.params.enumerated() where i < gpu.writtenInputs.count {
            if gpu.writtenInputs[i] != p.live { changed = true; gpu.writtenInputs[i] = p.live }
        }
        guard changed else { return }
        gpu.writtenVersion = version
        gradientColors.removeAll(keepingCapacity: true)
        for c in base { gradientColors.append(PaletteParams.adjust(c) { palette.bank.live($0) }) }
        writeGradient(gradientColors, into: gpu.advance())
    }

    /// Writes colors as an even 256-step gradient into a 256×1 RGBA16Float texture.
    private func writeGradient(_ colors: [SIMD3<Float>], into tex: MTLTexture) {
        guard colors.count >= 2 else { return }
        for i in 0..<256 {
            let x = Float(i) / 255 * Float(colors.count - 1)
            let lo = min(Int(x), colors.count - 2)
            let c = simd_mix(colors[lo], colors[lo + 1], SIMD3(repeating: x - Float(lo)))
            gradientPixels[i * 4] = Float16(c.x)
            gradientPixels[i * 4 + 1] = Float16(c.y)
            gradientPixels[i * 4 + 2] = Float16(c.z)
        }
        gradientPixels.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256 * 8)
        }
    }
}
