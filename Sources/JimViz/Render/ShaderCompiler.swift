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
    /// Generators: the mesh named by a `// @mesh` line.
    var mesh: MeshShape?
    /// Files pulled in by `// @include`, so editing one recompiles this shader.
    var includes: [URL] = []
}

/// Compiles shader files at runtime.
///
/// Each file is compiled as: common.metal + a generated `Params` struct + the file itself.
/// The struct comes from `// @param name default min max [int]` comments, so shader
/// authors write `p.amount` and the UI gets a knob for free. A param flagged `rate` also gets
/// a `<name>Phase` field after all the others: its value integrated over time.
/// A `// @include file.metal` line is replaced by that file (next to the shader), so a family
/// of shaders can share code and knobs; its `// @param`s count as the shader's own, in place.
final class ShaderCompiler {
    let device: MTLDevice
    private let commonURL: URL

    init(device: MTLDevice, commonURL: URL) {
        self.device = device
        self.commonURL = commonURL
    }

    func compile(_ url: URL) throws -> CompiledShader {
        let name = url.lastPathComponent
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw ShaderError(file: name, message: "file not found")
        }
        let (body, includes) = try Self.expandIncludes(raw, name: name, dir: url.deletingLastPathComponent())
        guard let common = try? String(contentsOf: commonURL, encoding: .utf8) else {
            throw ShaderError(file: "common.metal", message: "file not found")
        }
        let defs = ParamDef.parse(shaderSource: body)
        let inputs = StreamInputDef.parse(shaderSource: body)
        var mesh: MeshShape?
        if let line = body.split(separator: "\n").first(where: { $0.hasPrefix("// @mesh ") }) {
            let shape = line.dropFirst("// @mesh ".count).trimmingCharacters(in: .whitespaces)
            guard let m = MeshShape(rawValue: shape) else { throw ShaderError(file: name, message: "unknown mesh \(shape)") }
            let declared = defs.filter(\.rebuildsMesh).map(\.name)
            guard Set(declared) == Set(m.meshParams) else {
                throw ShaderError(file: name, message: "mesh \(shape) needs mesh params \(m.meshParams.joined(separator: ", ")), has \(declared.joined(separator: ", "))")
            }
            mesh = m
        }
        if let clash = inputs.first(where: { v in defs.contains { $0.name == v.name } }) {
            throw ShaderError(file: name, message: "\(clash.kind.rawValue) input \(clash.name) has the same name as a param")
        }
        let phases = defs.filter(\.isRate).map { "\($0.name)Phase" }
        if let clash = phases.first(where: { n in defs.contains { $0.name == n } || inputs.contains { $0.name == n } }) {
            throw ShaderError(file: name, message: "\(clash) is generated for a rate param and can't be declared too")
        }
        let fields = defs.isEmpty ? "    float _unused;"
            : (defs.map(\.name) + phases).map { "    float \($0);" }.joined(separator: "\n")
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
                                  selfHistory: body.contains("// @history self"), inputs: inputs,
                                  mesh: mesh, includes: includes)
        } catch {
            throw ShaderError(file: name, message: Self.summarize(error))
        }
    }

    /// Replaces each `// @include file` line with the file, with `#line` marks so errors name it.
    private static func expandIncludes(_ source: String, name: String, dir: URL) throws -> (String, [URL]) {
        var out: [String] = [], includes: [URL] = []
        for (i, line) in source.components(separatedBy: "\n").enumerated() {
            guard line.hasPrefix("// @include ") else { out.append(line); continue }
            let file = line.dropFirst("// @include ".count).trimmingCharacters(in: .whitespaces)
            let url = dir.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ShaderError(file: name, message: "include \(file) not found")
            }
            includes.append(url)
            out += ["#line 1 \"\(file)\"", text, "#line \(i + 2) \"\(name)\""]
        }
        return (out.joined(separator: "\n"), includes)
    }

    /// Keeps the first few `error:` lines from the Metal compiler output.
    static func summarize(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        let errors = text.split(separator: "\n").filter { $0.contains("error:") }
        if errors.isEmpty { return text }
        return errors.prefix(3).joined(separator: "\n")
    }
}
