import AppKit
import Metal
import QuartzCore
import Observation
import simd

// MARK: - Runtime scene objects (built on main, read by the render thread)

final class GeneratorRuntime {
    let type: String
    let shape: MeshShape
    let detail: Int
    let bank: ParamBank
    let meshPipeline: MTLRenderPipelineState
    let backgroundPipeline: MTLRenderPipelineState
    let vertexBuffer: MTLBuffer
    let vertexCount: Int
    /// Declared with `// @video`, `// @spectrum`, `// @palette`; bound from texture(0) up.
    let inputs: [StreamInputDef]

    init(type: String, shape: MeshShape, detail: Int, bank: ParamBank,
         meshPipeline: MTLRenderPipelineState, backgroundPipeline: MTLRenderPipelineState,
         vertexBuffer: MTLBuffer, vertexCount: Int, inputs: [StreamInputDef]) {
        self.type = type; self.shape = shape; self.detail = detail; self.bank = bank
        self.inputs = inputs
        self.meshPipeline = meshPipeline; self.backgroundPipeline = backgroundPipeline
        self.vertexBuffer = vertexBuffer; self.vertexCount = vertexCount
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

    init(id: String, effect: String, presetLabel: String?, enabled: Bool, bank: ParamBank,
         pipeline: MTLRenderPipelineState?, selfHistory: Bool, inputs: [StreamInputDef] = []) {
        self.inputs = inputs
        self.id = id; self.effect = effect; self.presetLabel = presetLabel; self.enabled = enabled; self.bank = bank
        self.pipeline = pipeline; self.selfHistory = selfHistory
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

    init(_ colors: [SIMD3<Float>], bank: ParamBank = ParamBank(defs: PaletteParams.defs, values: [:])) {
        self.bank = bank
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
    case audio, clock, midi(MIDIInputRuntime), webcam(WebcamRuntime)

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
    let generator: GeneratorRuntime?
    /// Preset ids each device was loaded from, and display labels, for the UI.
    let generatorPreset: String?
    let generatorLabel: String?
    /// Audio In, Clock and MIDI inputs, in chain order.
    let inputs: [InputDevice]
    let modulators: [ModulatorRuntime]
    let midiInputs: [MIDIInputRuntime]
    let webcams: [WebcamRuntime]
    /// Every stream output (video, spectrum, palette) and stream input in the chain, in chain order.
    let streamOutputs: [StreamOutput]
    let streamInputs: [StreamInput]
    /// Which stream feeds each stream input, by input key (`generator.bgVideo`). Active routes only.
    let streamBindings: [String: StreamOutput]
    let camera: ParamBank
    let cameraPreset: String?
    let cameraLabel: String
    let effects: [EffectRuntime]
    let palette: PaletteModel
    let palettePreset: String?
    let paletteLabel: String
    /// Every output in the chain, in chain order.
    let outputs: [OutputSignal]
    let mappings: [MappingRuntime]
    let banks: [ParamBank]
    /// Knob banks by target prefix: `generator`, `camera`, `post.<id>`, `mod.<id>`.
    let banksByPath: [String: ParamBank]
    /// False without Audio In; audio outputs then read 0.
    let hasAudioInput: Bool
    let hasClock: Bool
    /// Every device's chain key, left to right: inputs, `camera`, `palette`, `generator`, `post.<id>`.
    let deviceKeys: [String]

    init(name: String, generatorPreset: String?, generatorLabel: String?, generator: GeneratorRuntime?,
         inputs: [InputDevice], modulators: [ModulatorRuntime],
         streamOutputs: [StreamOutput], streamBindings: [String: StreamOutput],
         camera: ParamBank, cameraPreset: String?, cameraLabel: String,
         effects: [EffectRuntime], palettePreset: String?, palette: PaletteModel, paletteLabel: String,
         outputs: [OutputSignal], mappings: [MappingRuntime], banksByPath: [String: ParamBank]) {
        self.name = name; self.generator = generator
        self.generatorPreset = generatorPreset; self.generatorLabel = generatorLabel
        self.inputs = inputs
        self.modulators = modulators
        midiInputs = inputs.compactMap { if case .midi(let m) = $0 { return m } else { return nil } }
        webcams = inputs.compactMap { if case .webcam(let w) = $0 { return w } else { return nil } }
        self.streamOutputs = streamOutputs
        self.streamBindings = streamBindings
        streamInputs = (generator?.inputs.map { StreamInput(key: "generator.\($0.name)", label: $0.label, kind: $0.kind) } ?? [])
            + effects.flatMap { fx in fx.inputs.map { StreamInput(key: "post.\(fx.id).\($0.name)", label: $0.label, kind: $0.kind) } }
        self.camera = camera; self.cameraPreset = cameraPreset; self.cameraLabel = cameraLabel
        self.effects = effects; self.palette = palette; self.palettePreset = palettePreset; self.paletteLabel = paletteLabel
        self.outputs = outputs; self.mappings = mappings; self.banksByPath = banksByPath
        hasAudioInput = inputs.contains { $0.id == "audio" }
        hasClock = inputs.contains { $0.id == "clock" }
        deviceKeys = inputs.map(\.id) + modulators.map { "mod.\($0.id)" } + ["camera", "palette"] + (generator == nil ? [] : ["generator"]) + effects.map { "post.\($0.id)" }
        banks = [palette.bank] + webcams.map(\.bank) + modulators.map(\.bank) + (generator.map { [$0.bank] } ?? []) + [camera] + effects.map(\.bank)
    }

    /// Render thread, once per frame: updates outputs, then applies mappings to every knob.
    func modulate(_ input: SignalFrame) {
        var f = input
        if !hasAudioInput { f.muteAudio() }
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
    private var sceneTex: MTLTexture!
    private var sceneTexB: MTLTexture!
    private var ping: MTLTexture!
    private var pong: MTLTexture!
    /// Final output of the previous frame. Sampled by feedback effects and presented.
    private(set) var history: MTLTexture!

    /// Two textures per self-history effect, swapped each frame. Render thread only.
    private var effectHistory: [String: (current: MTLTexture, previous: MTLTexture)] = [:]
    /// Rotated per scene pass: the palette's inputs can change every frame, and a transition
    /// draws two palettes in one frame, so no texture is rewritten while the GPU may read it.
    private var paletteTextures: [MTLTexture] = []
    private var paletteIndex = 0
    private var paletteTex: MTLTexture { paletteTextures[paletteIndex] }
    /// Rotated per frame so the CPU never overwrites a texture the GPU is still reading.
    private var spectrumTextures: [MTLTexture] = []
    private var spectrumIndex = 0
    private var spectrumTex: MTLTexture { spectrumTextures[spectrumIndex] }
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
    private let depthOn: MTLDepthStencilState
    private let depthOff: MTLDepthStencilState

    // Camera state integrated over time so speed changes never jump.
    private var orbit: Float = 0
    /// Orbit position as 0...1 of a turn, for the camera's output.
    var orbitPhase: Float { let x = orbit / (2 * .pi); return x - floor(x) }
    private var rollAccum: Float = 0

    init(device: MTLDevice) {
        self.device = device
        queue = device.makeCommandQueue()!
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 256, height: 1, mipmapped: false)
        pd.usage = .shaderRead
        paletteTextures = (0..<8).map { _ in device.makeTexture(descriptor: pd)! }
        let on = MTLDepthStencilDescriptor()
        on.depthCompareFunction = .less
        on.isDepthWriteEnabled = true
        depthOn = device.makeDepthStencilState(descriptor: on)!
        let off = MTLDepthStencilDescriptor()
        off.depthCompareFunction = .always
        off.isDepthWriteEnabled = false
        depthOff = device.makeDepthStencilState(descriptor: off)!
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: AudioAnalyzer.spectrumBins,
                                                          height: 1, mipmapped: false)
        sd.usage = .shaderRead
        spectrumTextures = (0..<4).map { _ in device.makeTexture(descriptor: sd)! }
        let zeros = [Float](repeating: 0, count: AudioAnalyzer.spectrumBins)
        for _ in spectrumTextures { updateSpectrum(zeros) }
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        bd.usage = .shaderRead
        blackTexture = device.makeTexture(descriptor: bd)!
        blackTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](arrayLiteral: 0, 0, 0, 255), bytesPerRow: 4)
        greyRamp = device.makeTexture(descriptor: pd)!
        writeGradient([SIMD3(0, 0, 0), SIMD3(1, 1, 1)], into: greyRamp)
        makeTargets()
        makePresentPipeline()
        makeTransitionPipeline()
    }

    /// Uploads this frame's spectrum. Call once per frame before `encode`.
    func updateSpectrum(_ bins: [Float]) {
        spectrumIndex = (spectrumIndex + 1) % spectrumTextures.count
        bins.withUnsafeBytes { raw in
            spectrumTex.replace(region: MTLRegionMake2D(0, 0, bins.count, 1), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: bins.count * 4)
        }
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
        sceneTexB = tex(Self.workFormat, usage: [.renderTarget, .shaderRead])
        ping = tex(Self.workFormat, usage: [.renderTarget, .shaderRead])
        pong = tex(Self.workFormat, usage: [.renderTarget, .shaderRead])
        history = tex(Self.workFormat, usage: [.renderTarget, .shaderRead])
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
        func pipe(_ vf: MTLFunction, _ ff: MTLFunction) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            d.colorAttachments[0].pixelFormat = Self.workFormat
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = Self.sampleCount
            return try device.makeRenderPipelineState(descriptor: d)
        }
        do {
            return (try pipe(v, f), try pipe(bv, bf))
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
            var params = cam.bank.packed()
            var vf = f
            vf.resolution = SIMD2(Float(Self.videoSize.width), Float(Self.videoSize.height))
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(frame.texture, index: 0)
            enc.setFragmentBytes(&vf, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.setFragmentBytes(&params, length: params.count * 4, index: 1)
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
        var params = cam.bank.packed()
        var vf = f
        vf.resolution = SIMD2(Float(target.width), Float(target.height))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(raw, index: 0)
        enc.setFragmentTexture(cam.depthHistory, index: 1)
        enc.setFragmentBytes(&vf, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        enc.setFragmentBytes(&params, length: params.count * 4, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: target, to: cam.depthHistory)
            blit.endEncoding()
        }
        cmd.addCompletedHandler { _ in withExtendedLifetime(raw) {} }
    }

    /// Binds a shader's inputs from texture `first` up and returns the connected-inputs bitmask
    /// for `Frame.inputs` (bit n for texture(n)). Unconnected video and spectrum get black, an
    /// unconnected palette the grey ramp. Generators also get them in the vertex stage, at the
    /// same indices, so the spectrum or a video (like a webcam's depth) can move the mesh.
    private func bindInputs(_ enc: MTLRenderCommandEncoder, _ inputs: [StreamInputDef], path: String,
                            scene: RenderScene, from first: Int, vertex: Bool = false) -> Float {
        var mask = 0
        for (i, input) in inputs.enumerated() {
            let source = scene.streamBindings["\(path).\(input.name)"]
            let tex: MTLTexture
            switch source?.kind {
            case .video?: tex = source?.texture ?? blackTexture
            case .spectrum?: tex = spectrumTex
            case .palette?: tex = paletteTex
            default: tex = input.kind == .palette ? greyRamp : blackTexture
            }
            if source != nil { mask |= 1 << (first + i) }
            enc.setFragmentTexture(tex, index: first + i)
            if vertex { enc.setVertexTexture(tex, index: first + i) }
        }
        return Float(mask)
    }

    func makeMesh(_ shape: MeshShape, detail: Int) -> (MTLBuffer, Int) {
        let verts = MeshBuilder.build(shape, detail: detail)
        let buf = device.makeBuffer(bytes: verts, length: MemoryLayout<MeshVertex>.stride * verts.count,
                                    options: .storageModeShared)!
        return (buf, verts.count)
    }

    // MARK: Frame encoding

    func encode(_ cmd: MTLCommandBuffer, scene: RenderScene, frame f: inout FrameUniforms) {
        encodeScene(cmd, scene: scene, frame: &f, into: history)
    }

    func encodeScene(_ cmd: MTLCommandBuffer, scene: RenderScene, frame f: inout FrameUniforms, into target: MTLTexture) {
        encodeWebcams(cmd, scene, &f)
        f.resolution = SIMD2(Float(outputSize.width), Float(outputSize.height))
        updatePalette(scene.palette)
        var cam = cameraUniforms(scene.camera, frame: f)

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

        if let gen = scene.generator {
            var genParams = gen.bank.packed()
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                enc.label = "scene"
                f.inputs = bindInputs(enc, gen.inputs, path: "generator", scene: scene, from: 0, vertex: true)
                enc.setFragmentBytes(&f, length: MemoryLayout<FrameUniforms>.stride, index: 0)
                enc.setFragmentBytes(&genParams, length: genParams.count * 4, index: 1)
                enc.setFragmentBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 2)

                enc.setRenderPipelineState(gen.backgroundPipeline)
                enc.setDepthStencilState(depthOff)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

                enc.setRenderPipelineState(gen.meshPipeline)
                enc.setDepthStencilState(depthOn)
                enc.setCullMode(.none)
                enc.setVertexBuffer(gen.vertexBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&f, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                enc.setVertexBytes(&genParams, length: genParams.count * 4, index: 2)
                enc.setVertexBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 3)
                let instances = max(1, Int(gen.bank["instances"]?.live ?? 1))
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gen.vertexCount, instanceCount: instances)
                enc.endEncoding()
            }
        } else {
            // No generator assigned: clear to black
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                enc.label = "clear"
                enc.endEncoding()
            }
        }

        // Post chain, ping-ponging between two targets.
        var src: MTLTexture = sceneTex
        for fx in scene.effects where fx.enabled {
            guard let pipeline = fx.pipeline else { continue }
            var dst: MTLTexture = src === ping ? pong! : ping!
            var historyTex: MTLTexture = history
            if fx.selfHistory {
                var pair = effectHistory[fx.id] ?? (makeWorkTexture(), makeWorkTexture())
                swap(&pair.current, &pair.previous)
                effectHistory[fx.id] = pair
                dst = pair.current
                historyTex = pair.previous
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = dst
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { continue }
            enc.label = fx.id
            var params = fx.bank.packed()
            var ff = f
            ff.inputs = bindInputs(enc, fx.inputs, path: "post.\(fx.id)", scene: scene, from: 2)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentTexture(historyTex, index: 1)
            enc.setFragmentBytes(&ff, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.setFragmentBytes(&params, length: params.count * 4, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            src = dst
        }

        if effectHistory.count > scene.effects.count {
            let live = Set(scene.effects.map(\.id))
            effectHistory = effectHistory.filter { live.contains($0.key) }
        }

        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: src, to: target)
            blit.endEncoding()
        }
    }

    /// Blends two scenes together using a 300ms crossfade.
    func encodeTransition(
        _ cmd: MTLCommandBuffer,
        from fromScene: RenderScene,
        to toScene: RenderScene,
        progress: Float,
        frame f: inout FrameUniforms
    ) {
        encodeScene(cmd, scene: fromScene, frame: &f, into: sceneTex)
        encodeScene(cmd, scene: toScene, frame: &f, into: sceneTexB)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = history
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "crossfade"

        var p = progress
        enc.setRenderPipelineState(transitionPipeline)
        enc.setFragmentTexture(sceneTex, index: 0)
        enc.setFragmentTexture(sceneTexB, index: 1)
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

    private func cameraUniforms(_ c: ParamBank, frame f: FrameUniforms) -> CameraUniforms {
        let t = f.time
        orbit += c.live("orbitSpeed") * f.dt
        rollAccum += c.live("rollSpeed") * 90 * f.dt
        let dist = c.live("distance"), sway = c.live("sway"), shake = c.live("shake")
        let swing = c.live("swing")
        let angle = swing > 0 ? sin(orbit) * swing * .pi / 180 : orbit
        var eye = SIMD3<Float>(cos(angle) * dist, c.live("height"), sin(angle) * dist)
        eye += SIMD3(sin(t * 0.37), cos(t * 0.23) * 0.5, sin(t * 0.29 + 1)) * sway
        eye += SIMD3(sin(t * 31.7), sin(t * 23.3 + 2), sin(t * 27.1 + 4)) * shake * 0.25
        let target = SIMD3<Float>(0, c.live("lookY"), 0)
        let rollRad = (c.live("roll") + rollAccum) * .pi / 180
        let up = SIMD3<Float>(sin(rollRad), cos(rollRad), 0)
        let view = simd_float4x4.lookAt(eye: eye, target: target, up: simd_normalize(up))
        let proj = simd_float4x4.perspective(fovY: c.live("fov") * .pi / 180,
                                             aspect: f.resolution.x / f.resolution.y, near: 0.05, far: 300)
        return CameraUniforms(viewProj: proj * view, position: SIMD4(eye, 1))
    }

    /// Writes the 256-step gradient, with the palette's inputs applied, into the next texture.
    private func updatePalette(_ palette: PaletteModel) {
        let (_, base) = palette.snapshot()
        guard base.count >= 2 else { return }
        paletteIndex = (paletteIndex + 1) % paletteTextures.count
        writeGradient(base.map { PaletteParams.adjust($0) { palette.bank.live($0) } }, into: paletteTex)
    }

    /// Writes colors as an even 256-step gradient into a 256×1 RGBA16Float texture.
    private func writeGradient(_ colors: [SIMD3<Float>], into tex: MTLTexture) {
        guard colors.count >= 2 else { return }
        var pixels = [Float16](repeating: 1, count: 256 * 4)
        for i in 0..<256 {
            let x = Float(i) / 255 * Float(colors.count - 1)
            let lo = min(Int(x), colors.count - 2)
            let c = simd_mix(colors[lo], colors[lo + 1], SIMD3(repeating: x - Float(lo)))
            pixels[i * 4] = Float16(c.x)
            pixels[i * 4 + 1] = Float16(c.y)
            pixels[i * 4 + 2] = Float16(c.z)
        }
        tex.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 256 * 8)
    }
}
