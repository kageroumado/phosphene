import Foundation

/// One Wallpaper Engine shader (`shaders/<name>.vert` + `.frag`) with its includes
/// resolved and its annotations read.
///
/// Uniform annotations sit in trailing comments:
/// `uniform float g_Speed; // {"material":"speed","default":5}` binds the uniform to the
/// material key `speed`, and a sampler's `"combo":"MASK"` turns the `MASK` define on
/// when a texture fills that slot. `// [COMBO] {"combo":"X","default":0}` lines
/// declare preprocessor switches with their defaults.
nonisolated struct WEShaderSource {
    struct Annotation {
        let materialKey: String?
        let defaultValue: Any?
        let combo: String?
        let defaultTexture: String?
    }

    let name: String
    let vertex: String
    let fragment: String
    let comboDefaults: [String: Int]
    /// Keyed by uniform name.
    let annotations: [String: Annotation]
    /// Texture slots whose format the shader switches on (`TEXnFORMAT`).
    let formatSlots: Set<Int>
    /// The shader reads Wallpaper Engine's audio spectrum: a visualizer, which
    /// a video wallpaper has nothing to feed.
    let usesAudio: Bool

    init(name: String, files: WEFileSystem) throws {
        guard let vertex = files.text("shaders/\(name).vert"), let fragment = files.text("shaders/\(name).frag")
        else { throw WEError.missing("shader \(name)") }
        self.name = name
        var included = Set<String>()
        self.vertex = try Self.resolveIncludes(vertex, files: files, included: &included, depth: 0)
        included.removeAll()
        self.fragment = try Self.resolveIncludes(fragment, files: files, included: &included, depth: 0)
        guard self.vertex.utf8.count + self.fragment.utf8.count <= WELimit.shaderBytes else {
            throw WEError.unsupported("a shader of \(name) larger than \(WELimit.shaderBytes / 1_024) KB")
        }

        var combos: [String: Int] = [:]
        var annotations: [String: Annotation] = [:]
        for line in (self.vertex + "\n" + self.fragment).split(separator: "\n") {
            let line = String(line)
            if let range = line.range(of: "[COMBO]"),
               let json = WEJSON.object(from: Data(line[range.upperBound...].utf8)),
               let combo = json["combo"] as? String {
                combos[combo] = WEJSON.int(json["default"], in: -1_000 ... 1_000, default: 0)
                continue
            }
            guard let match = unsafe line.firstMatch(of: Pattern.annotatedUniform) else { continue }
            let uniform = String(match.output.2)
            let json = WEJSON.object(from: Data(match.output.3.utf8)) ?? [:]
            let isSampler = match.output.1.hasPrefix("sampler")
            annotations[uniform] = Annotation(
                materialKey: json["material"] as? String,
                defaultValue: isSampler ? nil : json["default"],
                combo: json["combo"] as? String,
                defaultTexture: isSampler ? json["default"] as? String : nil,
            )
        }
        comboDefaults = combos
        self.annotations = annotations
        formatSlots = Set(
            unsafe (self.vertex + self.fragment).matches(of: Pattern.formatSlot).compactMap { Int($0.output.1) },
        )
        usesAudio = self.vertex.contains("g_AudioSpectrum") || self.fragment.contains("g_AudioSpectrum")
    }

    /// The patterns, compiled once. `Regex` is not `Sendable`, and none of these is
    /// ever mutated.
    private enum Pattern {
        nonisolated(unsafe) static let annotatedUniform =
            /^\s*uniform\s+(\w+)\s+(\w+)\s*(?:\[[^\]]*\])?\s*;\s*\/\/\s*(\{.*\})\s*$/
        nonisolated(unsafe) static let include = /^\s*#include\s+"([^"]+)"/
        nonisolated(unsafe) static let formatSlot = /TEX(\d)FORMAT/
        nonisolated(unsafe) static let uniformDeclaration = /^\s*uniform\s+\w+\s+(\w+)\s*;/
        nonisolated(unsafe) static let identifier = /[A-Za-z_]\w*/
        nonisolated(unsafe) static let conditionLine = /^[ \t]*#\s*(?:if|elif)\b/.wordBoundaryKind(.simple)
        nonisolated(unsafe) static let conditionToken = /(defined\s*\(?\s*)?\b([A-Za-z_]\w*)\b/.wordBoundaryKind(.simple)
        /// `[ \t]*` rather than `\s*`: a pattern that can swallow newlines backtracks
        /// across every blank line that follows, quadratic in the file.
        nonisolated(unsafe) static let directiveToStrip = /^[ \t]*#(?:version|require)[^\n]*/.anchorsMatchLineEndings()
        nonisolated(unsafe) static let intLoop = /for\s*\(\s*int\s+(\w+)\s*=\s*([^;]+);/
        nonisolated(unsafe) static let define = /#define\s+(\w+)/
        nonisolated(unsafe) static let ifdef = /#\s*ifn?def\s+(\w+)/
        nonisolated(unsafe) static let defined = /defined\s*\(?\s*(\w+)/
        nonisolated(unsafe) static let definedCall = /defined\s*\(?\s*\w+\s*\)?/
        nonisolated(unsafe) static let condition =
            /^[ \t]*#(?:if|elif)\b([^\n]*)/.wordBoundaryKind(.simple).anchorsMatchLineEndings()
    }

    private static func resolveIncludes(
        _ source: String, files: WEFileSystem, included: inout Set<String>, depth: Int,
    ) throws -> String {
        guard depth <= WELimit.includeDepth else { throw WEError.malformed("shader includes nested too deep") }
        var output: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if let match = unsafe line.firstMatch(of: Pattern.include) {
                let path = "shaders/" + match.output.1
                guard !included.contains(path) else { continue }
                included.insert(path)
                if let header = files.text(path) {
                    try output.append(resolveIncludes(header, files: files, included: &included, depth: depth + 1))
                }
                continue
            }
            output.append(String(line))
        }
        return output.joined(separator: "\n")
    }

    /// GLSL 4.10 core for this shader with `combos` defined.
    func glsl(combos: [String: Int]) -> (vertex: String, fragment: String) {
        (
            Self.header(for: Self.translate(vertex, stage: .vertex), combos: combos),
            Self.header(for: Self.translate(fragment, stage: .fragment), combos: combos, fragment: true),
        )
    }

    private static func header(for body: String, combos: [String: Int], fragment: Bool = false) -> String {
        var header = "#version 410\n#define GLSL 1\n"
        for (name, value) in combos.sorted(by: { $0.key < $1.key }) {
            header += "#define \(name) \(value)\n"
        }
        // Wallpaper Engine's compiler reads a switch nobody set as 0 in `#if`, where
        // GLSL stops with an error. Names tested for existence (`#ifdef`, `defined`)
        // and names the source defines itself are left alone.
        let defined = definedNames(in: body)
        let presence = presenceTestedNames(in: body)
        let unset = conditionNames(in: body).subtracting(defined).subtracting(["GLSL"]).filter { combos[$0] == nil }
        for name in unset.subtracting(presence).sorted() {
            header += "#define \(name) 0\n"
        }
        // A name tested both ways stays undefined for `#ifdef` and reads 0 in `#if`.
        let both = unset.intersection(presence)
        var body = body
        if !both.isEmpty {
            body = body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                guard unsafe line.firstMatch(of: Pattern.conditionLine) != nil else { return String(line) }
                return unsafe String(line).replacing(Pattern.conditionToken) { match in
                    match.output.1 == nil && both.contains(String(match.output.2)) ? "0" : String(match.output.0)
                }
            }.joined(separator: "\n")
        }
        let (hoisted, rest) = hoistEarlyUniforms(body)
        return header + prelude + (fragment ? "\nout vec4 out_FragColor;\n" : "\n") + hoisted + rest
    }

    /// Move each uniform declaration that the code uses before declaring it (headers
    /// reading `g_Texture0` ahead of the shader's own declaration) to the top.
    /// Wallpaper Engine gathers uniforms into one block, so its shaders rely on this.
    private static func hoistEarlyUniforms(_ body: String) -> (hoisted: String, rest: String) {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The first line each identifier appears on, line comments left out.
        var firstUse: [String: Int] = [:]
        for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            for match in unsafe line.matches(of: Pattern.identifier) {
                let identifier = String(match.output)
                if firstUse[identifier] == nil {
                    firstUse[identifier] = index
                }
            }
        }
        var hoisted: [String] = []
        var seen = Set<String>()
        for index in lines.indices {
            guard let match = unsafe lines[index].firstMatch(of: Pattern.uniformDeclaration) else { continue }
            let name = String(match.output.1)
            guard seen.insert(name).inserted else { continue }
            if let first = firstUse[name], first < index {
                hoisted.append(lines[index])
                lines[index] = ""
            }
        }
        return (hoisted.isEmpty ? "" : hoisted.joined(separator: "\n") + "\n", lines.joined(separator: "\n"))
    }

    private enum Stage {
        case vertex
        case fragment
    }

    /// HLSL spellings Wallpaper Engine's shaders use, in GLSL.
    static let prelude = """
    #define frac fract
    #define lerp mix
    #define saturate(x) clamp(x, 0.0, 1.0)
    #define mul(x, y) ((y) * (x))
    #define texSample2D texture
    #define texSample2DLod textureLod
    #define texSample2DBackBuffer texture
    #define atan2 atan
    #define ddx dFdx
    #define ddy dFdy
    #define fmod(x, y) ((x) - (y) * trunc((x) / (y)))
    #define log10(x) (log2(x) * 0.301029995663981)
    #define rsqrt inversesqrt
    #define CAST2(x) (vec2(x))
    #define CAST3(x) (vec3(x))
    #define CAST4(x) (vec4(x))
    #define CAST3X3(x) (mat3(x))
    #define float2 vec2
    #define float3 vec3
    #define float4 vec4
    #define float3x3 mat3
    #define float4x4 mat4
    #define sampler2DComparison sampler2DShadow
    #define texSample2DCompare(s, uv, reference) texture(s, vec3(uv, reference))
    """

    private static func translate(_ source: String, stage: Stage) -> String {
        var text = unsafe source.replacing(Pattern.directiveToStrip, with: "")
        // HLSL narrows a float initializer into an int loop counter; GLSL needs the cast.
        text = unsafe text.replacing(Pattern.intLoop) { match in
            "for (int \(match.output.1) = int(\(match.output.2));"
        }
        text = text.replacing(/\battribute\b/.wordBoundaryKind(.simple), with: "in")
        text = text.replacing(/\bvarying\b/.wordBoundaryKind(.simple), with: stage == .vertex ? "out" : "in")
        text = text.replacing(/\btexture2DLod\b/.wordBoundaryKind(.simple), with: "textureLod")
        text = text.replacing(/\btexture2D\b/.wordBoundaryKind(.simple), with: "texture")
        // `sample` is a reserved word from GLSL 4.0 on.
        text = text.replacing(/\bsample\b/.wordBoundaryKind(.simple), with: "sample_")
        if stage == .fragment {
            text = text.replacing(/\bgl_FragColor\b/.wordBoundaryKind(.simple), with: "out_FragColor")
        }
        return text
    }

    private static func definedNames(in source: String) -> Set<String> {
        unsafe Set(source.matches(of: Pattern.define).map { String($0.output.1) })
    }

    private static func presenceTestedNames(in source: String) -> Set<String> {
        var names = unsafe Set(source.matches(of: Pattern.ifdef).map { String($0.output.1) })
        unsafe names.formUnion(source.matches(of: Pattern.defined).map { String($0.output.1) })
        return names
    }

    private static func conditionNames(in source: String) -> Set<String> {
        var names = Set<String>()
        for match in unsafe source.matches(of: Pattern.condition) {
            let expression = unsafe match.output.1.replacing(Pattern.definedCall, with: "")
            for token in unsafe expression.matches(of: Pattern.identifier) {
                names.insert(String(token.output))
            }
        }
        return names
    }
}

/// A linked program plus what it needs to be fed.
final nonisolated class WEProgram {
    let program: UInt32
    let source: WEShaderSource
    let uniforms: [GL.ActiveUniform]

    init(gl: GL, source: WEShaderSource, combos: [String: Int]) throws {
        let code = source.glsl(combos: combos)
        do {
            program = try gl.makeProgram(vertex: code.vertex, fragment: code.fragment)
        } catch let GLError.shader(log) {
            throw GLError.shader("\(source.name): \(log.prefix(600))")
        }
        self.source = source
        uniforms = gl.activeUniforms(program)
    }
}

/// Compiles each (shader, combos) pair once per render session.
final nonisolated class WEProgramCache {
    private let gl: GL
    private let files: WEFileSystem
    private var sources: [String: WEShaderSource] = [:]
    private var programs: [String: WEProgram] = [:]

    init(gl: GL, files: WEFileSystem) {
        self.gl = gl
        self.files = files
    }

    func source(_ name: String) throws -> WEShaderSource {
        if let cached = sources[name] {
            return cached
        }
        let source = try WEShaderSource(name: name, files: files)
        sources[name] = source
        return source
    }

    func program(_ name: String, combos: [String: Int]) throws -> WEProgram {
        let key = name + "|" + combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        if let cached = programs[key] {
            return cached
        }
        let program = try WEProgram(gl: gl, source: source(name), combos: combos)
        programs[key] = program
        return program
    }

    func deleteAll() {
        for program in programs.values {
            gl.deleteProgram(program.program)
        }
        programs.removeAll()
    }
}
