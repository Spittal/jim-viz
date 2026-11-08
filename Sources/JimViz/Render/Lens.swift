import Metal

/// The scene's lens, a camera effect: a shader in Shaders/lenses that writes an ST map from its
/// knobs (`lens.<param>`). Its ST Map output (`lens.stmap`) goes into the Camera's Lens input,
/// which reprojects the rendered picture through it before the effects. Unmapped, it does
/// nothing and isn't drawn. Built on main, drawn by the render thread.
final class LensRuntime {
    static let key = "lens"
    /// Float32, so the lookup stays exact to a fraction of a pixel across the frame.
    static let format: MTLPixelFormat = .rg32Float

    /// Lens tool: a shader in Shaders/lenses, without extension (`distortion`).
    let type: String
    let preset: String?
    let label: String
    let bank: ParamBank
    /// Draws the ST map (`lens` fragment). Nil while the shader has never compiled.
    let pipeline: MTLRenderPipelineState?
    /// The ST map, at the output size. Carried over when the scene is rebuilt.
    let stmap: MTLTexture
    let output: StreamOutput
    /// The knob values the ST map was last drawn with. Render thread only.
    private var drawn: [Float] = []

    init(type: String, preset: String?, label: String, bank: ParamBank, pipeline: MTLRenderPipelineState?, stmap: MTLTexture) {
        self.type = type; self.preset = preset; self.label = label; self.bank = bank
        self.pipeline = pipeline; self.stmap = stmap
        output = StreamOutput(StreamOutput.stmapKey, "ST Map", device: "Lens", kind: .stmap, texture: stmap)
        drawn.reserveCapacity(bank.params.count * 2)
    }

    /// Render thread: whether the ST map needs drawing, because its knobs' live values (packed
    /// as the shader gets them) differ from the last draw. Records them as drawn. A rebuilt
    /// lens always draws once, so a recompiled shader shows straight away.
    func needsDraw() -> Bool {
        var changed = false
        bank.withPacked { ptr, length in
            let values = UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: length / 4)
            guard !drawn.elementsEqual(values) else { return }
            changed = true
            drawn.removeAll(keepingCapacity: true)
            drawn.append(contentsOf: values)
        }
        return changed
    }
}
