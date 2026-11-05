import Foundation
import Metal

struct ShaderError: Error, CustomStringConvertible {
    let file: String
    let message: String
    var description: String { "\(file): \(message)" }
}

struct CompiledShader {
    let url: URL
    let library: MTLLibrary
    let params: [ParamDef]
    /// Set by a `// @history self` line: texture(1) is the effect's own previous output.
    let selfHistory: Bool
    /// Inputs from `// @video`, `// @spectrum` and `// @palette` lines, in declaration order.
    /// Generators read them from texture(0) up, effects from texture(2) up; bit n of
    /// `f.inputs` is set when the input at texture(n) is connected.
    var inputs: [StreamInputDef] = []
}

/// Compiles shader files at runtime.
///
/// Each file is compiled as: common.metal + a generated `Params` struct + the file itself.
/// The struct comes from `// @param name default min max [int]` comments, so shader
/// authors write `p.amount` and the UI gets a knob for free.
final class ShaderCompiler {
    let device: MTLDevice
    private let commonURL: URL

    init(device: MTLDevice, commonURL: URL) {
        self.device = device
        self.commonURL = commonURL
    }

    func compile(_ url: URL) throws -> CompiledShader {
        let name = url.lastPathComponent
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            throw ShaderError(file: name, message: "file not found")
        }
        guard let common = try? String(contentsOf: commonURL, encoding: .utf8) else {
            throw ShaderError(file: "common.metal", message: "file not found")
        }
        let defs = ParamDef.parse(shaderSource: body)
        let inputs = StreamInputDef.parse(shaderSource: body)
        if let clash = inputs.first(where: { v in defs.contains { $0.name == v.name } }) {
            throw ShaderError(file: name, message: "\(clash.kind.rawValue) input \(clash.name) has the same name as a param")
        }
        let fields = defs.isEmpty ? "    float _unused;" : defs.map { "    float \($0.name);" }.joined(separator: "\n")
        let source = """
        #line 1 "common.metal"
        \(common)
        struct Params {
        \(fields)
        };
        #line 1 "\(name)"
        \(body)
        """
        let opts = MTLCompileOptions()
        if #available(macOS 15.0, *) { opts.mathMode = .fast } else { opts.fastMathEnabled = true }
        do {
            let lib = try device.makeLibrary(source: source, options: opts)
            return CompiledShader(url: url, library: lib, params: defs,
                                  selfHistory: body.contains("// @history self"), inputs: inputs)
        } catch {
            throw ShaderError(file: name, message: Self.summarize(error))
        }
    }

    /// Keeps the first few `error:` lines from the Metal compiler output.
    static func summarize(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        let errors = text.split(separator: "\n").filter { $0.contains("error:") }
        if errors.isEmpty { return text }
        return errors.prefix(3).joined(separator: "\n")
    }
}
