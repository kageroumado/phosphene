import Darwin
import Foundation

/// OpenGL 4.1 core, loaded at runtime with `dlsym`.
///
/// Wallpaper Engine's shaders are GLSL, so an OpenGL context compiles them with a
/// short dialect prelude. The framework is opened by path rather than linked: its
/// symbols are deprecated (every call would warn), and on a macOS without OpenGL the
/// loader fails with ``GLError/unavailable`` instead of the app failing to launch.
nonisolated enum GLConst {
    static let colorBufferBit: UInt32 = 0x4000
    static let texture2D: UInt32 = 0x0DE1
    static let rgba: UInt32 = 0x1908
    static let rgba8: UInt32 = 0x8058
    static let bgra: UInt32 = 0x80E1
    static let red: UInt32 = 0x1903
    static let r8: UInt32 = 0x8229
    static let rg: UInt32 = 0x8227
    static let rg8: UInt32 = 0x822B
    static let unsignedByte: UInt32 = 0x1401
    static let float: UInt32 = 0x1406
    static let unsignedInt8888Rev: UInt32 = 0x8367
    static let triangleStrip: UInt32 = 0x0005
    static let arrayBuffer: UInt32 = 0x8892
    static let streamDraw: UInt32 = 0x88E0
    static let staticDraw: UInt32 = 0x88E4
    static let framebuffer: UInt32 = 0x8D40
    static let readFramebuffer: UInt32 = 0x8CA8
    static let drawFramebuffer: UInt32 = 0x8CA9
    static let colorAttachment0: UInt32 = 0x8CE0
    static let framebufferComplete: UInt32 = 0x8CD5
    static let textureMinFilter: UInt32 = 0x2801
    static let textureMagFilter: UInt32 = 0x2800
    static let textureWrapS: UInt32 = 0x2802
    static let textureWrapT: UInt32 = 0x2803
    static let textureMaxLevel: UInt32 = 0x813D
    static let linear: Int32 = 0x2601
    static let nearest: Int32 = 0x2600
    static let linearMipmapLinear: Int32 = 0x2703
    static let clampToEdge: Int32 = 0x812F
    static let repeatWrap: Int32 = 0x2901
    static let texture0: UInt32 = 0x84C0
    static let vertexShader: UInt32 = 0x8B31
    static let fragmentShader: UInt32 = 0x8B30
    static let compileStatus: UInt32 = 0x8B81
    static let linkStatus: UInt32 = 0x8B82
    static let infoLogLength: UInt32 = 0x8B84
    static let activeUniforms: UInt32 = 0x8B86
    static let blend: UInt32 = 0x0BE2
    static let depthTest: UInt32 = 0x0B71
    static let cullFace: UInt32 = 0x0B44
    static let zero: UInt32 = 0
    static let one: UInt32 = 1
    static let srcAlpha: UInt32 = 0x0302
    static let oneMinusSrcAlpha: UInt32 = 0x0303
    static let packAlignment: UInt32 = 0x0D05
    static let packRowLength: UInt32 = 0x0D02
    static let unpackAlignment: UInt32 = 0x0CF5
    static let unpackRowLength: UInt32 = 0x0CF2
    static let compressedDXT1: UInt32 = 0x83F1
    static let compressedDXT3: UInt32 = 0x83F2
    static let compressedDXT5: UInt32 = 0x83F3

    // Uniform types reported by glGetActiveUniform.
    static let typeFloat: UInt32 = 0x1406
    static let typeVec2: UInt32 = 0x8B50
    static let typeVec3: UInt32 = 0x8B51
    static let typeVec4: UInt32 = 0x8B52
    static let typeInt: UInt32 = 0x1404
    static let typeBool: UInt32 = 0x8B56
    static let typeMat3: UInt32 = 0x8B5B
    static let typeMat4: UInt32 = 0x8B5C
    static let typeSampler2D: UInt32 = 0x8B5E
}

nonisolated enum GLError: LocalizedError {
    case unavailable
    case contextCreation(Int32)
    case shader(String)
    case framebuffer(UInt32)

    var errorDescription: String? {
        switch self {
        case .unavailable: "OpenGL is not available on this Mac."
        case let .contextCreation(code): "Could not create an OpenGL context (CGL error \(code))."
        case let .shader(log): "A wallpaper shader failed to compile: \(log)"
        case let .framebuffer(status): "An offscreen render target is incomplete (status \(status))."
        }
    }
}

/// The OpenGL entry points the scene renderer uses, resolved once per process.
@safe
final nonisolated class GL: @unchecked Sendable {
    typealias Enum = UInt32

    private typealias FnV_E = @convention(c) (Enum) -> Void
    private typealias FnV_EEEE = @convention(c) (Enum, Enum, Enum, Enum) -> Void
    private typealias FnV_U = @convention(c) (UInt32) -> Void
    private typealias FnV_UU = @convention(c) (UInt32, UInt32) -> Void
    private typealias FnV_EU = @convention(c) (Enum, UInt32) -> Void
    private typealias FnV_EI = @convention(c) (Enum, Int32) -> Void
    private typealias FnV_EEI = @convention(c) (Enum, Enum, Int32) -> Void
    private typealias FnV_IIII = @convention(c) (Int32, Int32, Int32, Int32) -> Void
    private typealias FnV_FFFF = @convention(c) (Float, Float, Float, Float) -> Void
    private typealias FnGen = @convention(c) (Int32, UnsafeMutablePointer<UInt32>) -> Void
    private typealias FnDel = @convention(c) (Int32, UnsafePointer<UInt32>) -> Void
    private typealias FnTexImage = @convention(c) (Enum, Int32, Int32, Int32, Int32, Int32, Enum, Enum, UnsafeRawPointer?) -> Void
    private typealias FnCompressedTexImage = @convention(c) (Enum, Int32, Enum, Int32, Int32, Int32, Int32, UnsafeRawPointer?) -> Void
    private typealias FnFramebufferTexture = @convention(c) (Enum, Enum, Enum, UInt32, Int32) -> Void
    private typealias FnCheckFramebuffer = @convention(c) (Enum) -> Enum
    private typealias FnReadPixels = @convention(c) (Int32, Int32, Int32, Int32, Enum, Enum, UnsafeMutableRawPointer?) -> Void
    private typealias FnCreateShader = @convention(c) (Enum) -> UInt32
    private typealias FnCreateProgram = @convention(c) () -> UInt32
    private typealias FnShaderSource = @convention(c) (UInt32, Int32, UnsafePointer<UnsafePointer<CChar>?>, UnsafePointer<Int32>?) -> Void
    private typealias FnGetiv = @convention(c) (UInt32, Enum, UnsafeMutablePointer<Int32>) -> Void
    private typealias FnInfoLog = @convention(c) (UInt32, Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<CChar>) -> Void
    private typealias FnBindAttrib = @convention(c) (UInt32, UInt32, UnsafePointer<CChar>) -> Void
    private typealias FnUniformLocation = @convention(c) (UInt32, UnsafePointer<CChar>) -> Int32
    private typealias FnActiveUniform = @convention(c) (
        UInt32, UInt32, Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>,
        UnsafeMutablePointer<Enum>, UnsafeMutablePointer<CChar>,
    ) -> Void
    private typealias FnUniform1i = @convention(c) (Int32, Int32) -> Void
    private typealias FnUniformfv = @convention(c) (Int32, Int32, UnsafePointer<Float>) -> Void
    private typealias FnUniformMatrix = @convention(c) (Int32, Int32, UInt8, UnsafePointer<Float>) -> Void
    private typealias FnBufferData = @convention(c) (Enum, Int, UnsafeRawPointer?, Enum) -> Void
    private typealias FnAttribPointer = @convention(c) (UInt32, Int32, Enum, UInt8, Int32, UnsafeRawPointer?) -> Void
    private typealias FnDrawArrays = @convention(c) (Enum, Int32, Int32) -> Void
    private typealias FnDrawArraysInstanced = @convention(c) (Enum, Int32, Int32, Int32) -> Void
    private typealias FnBlit = @convention(c) (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, UInt32, Enum) -> Void
    private typealias FnChoosePixelFormat = @convention(c) (UnsafePointer<UInt32>, UnsafeMutablePointer<OpaquePointer?>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias FnCreateContext = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    private typealias FnSetCurrent = @convention(c) (OpaquePointer?) -> Int32
    private typealias FnDestroy = @convention(c) (OpaquePointer?) -> Int32

    private let _viewport: FnV_IIII
    private let _clearColor: FnV_FFFF
    private let _clear: FnV_U
    private let _enable: FnV_E
    private let _disable: FnV_E
    private let _blendFuncSeparate: FnV_EEEE
    private let _genTextures: FnGen
    private let _deleteTextures: FnDel
    private let _bindTexture: FnV_EU
    private let _activeTexture: FnV_E
    private let _texImage2D: FnTexImage
    private let _compressedTexImage2D: FnCompressedTexImage
    private let _texParameteri: FnV_EEI
    private let _pixelStorei: FnV_EI
    private let _genFramebuffers: FnGen
    private let _deleteFramebuffers: FnDel
    private let _bindFramebuffer: FnV_EU
    private let _framebufferTexture2D: FnFramebufferTexture
    private let _checkFramebufferStatus: FnCheckFramebuffer
    private let _readPixels: FnReadPixels
    private let _blitFramebuffer: FnBlit
    private let _createShader: FnCreateShader
    private let _shaderSource: FnShaderSource
    private let _compileShader: FnV_U
    private let _getShaderiv: FnGetiv
    private let _getShaderInfoLog: FnInfoLog
    private let _deleteShader: FnV_U
    private let _createProgram: FnCreateProgram
    private let _attachShader: FnV_UU
    private let _bindAttribLocation: FnBindAttrib
    private let _linkProgram: FnV_U
    private let _getProgramiv: FnGetiv
    private let _getProgramInfoLog: FnInfoLog
    private let _useProgram: FnV_U
    private let _deleteProgram: FnV_U
    private let _getUniformLocation: FnUniformLocation
    private let _getActiveUniform: FnActiveUniform
    private let _uniform1i: FnUniform1i
    private let _uniform1fv: FnUniformfv
    private let _uniform2fv: FnUniformfv
    private let _uniform3fv: FnUniformfv
    private let _uniform4fv: FnUniformfv
    private let _uniformMatrix3fv: FnUniformMatrix
    private let _uniformMatrix4fv: FnUniformMatrix
    private let _genVertexArrays: FnGen
    private let _deleteVertexArrays: FnDel
    private let _bindVertexArray: FnV_U
    private let _genBuffers: FnGen
    private let _deleteBuffers: FnDel
    private let _bindBuffer: FnV_EU
    private let _bufferData: FnBufferData
    private let _vertexAttribPointer: FnAttribPointer
    private let _enableVertexAttribArray: FnV_U
    private let _vertexAttribDivisor: FnV_UU
    private let _drawArrays: FnDrawArrays
    private let _drawArraysInstanced: FnDrawArraysInstanced
    private let _choosePixelFormat: FnChoosePixelFormat
    private let _createContext: FnCreateContext
    private let _setCurrentContext: FnSetCurrent
    private let _destroyContext: FnDestroy
    private let _destroyPixelFormat: FnDestroy

    private static let frameworkPath = "/System/Library/Frameworks/OpenGL.framework/OpenGL"

    /// The process-wide loader; `nil` when the framework or a symbol is missing.
    static let shared: GL? = try? GL()

    // swiftlint:disable:next function_body_length
    private init() throws {
        guard let handle = unsafe dlopen(Self.frameworkPath, RTLD_NOW | RTLD_LOCAL) else { throw GLError.unavailable }
        func symbol<T>(_ name: String) throws -> T {
            guard let pointer = unsafe dlsym(handle, name) else { throw GLError.unavailable }
            return unsafe unsafeBitCast(pointer, to: T.self)
        }
        _viewport = try symbol("glViewport")
        _clearColor = try symbol("glClearColor")
        _clear = try symbol("glClear")
        _enable = try symbol("glEnable")
        _disable = try symbol("glDisable")
        _blendFuncSeparate = try symbol("glBlendFuncSeparate")
        unsafe _genTextures = unsafe try symbol("glGenTextures")
        unsafe _deleteTextures = unsafe try symbol("glDeleteTextures")
        _bindTexture = try symbol("glBindTexture")
        _activeTexture = try symbol("glActiveTexture")
        unsafe _texImage2D = unsafe try symbol("glTexImage2D")
        unsafe _compressedTexImage2D = unsafe try symbol("glCompressedTexImage2D")
        _texParameteri = try symbol("glTexParameteri")
        _pixelStorei = try symbol("glPixelStorei")
        unsafe _genFramebuffers = unsafe try symbol("glGenFramebuffers")
        unsafe _deleteFramebuffers = unsafe try symbol("glDeleteFramebuffers")
        _bindFramebuffer = try symbol("glBindFramebuffer")
        _framebufferTexture2D = try symbol("glFramebufferTexture2D")
        _checkFramebufferStatus = try symbol("glCheckFramebufferStatus")
        unsafe _readPixels = unsafe try symbol("glReadPixels")
        _blitFramebuffer = try symbol("glBlitFramebuffer")
        _createShader = try symbol("glCreateShader")
        unsafe _shaderSource = unsafe try symbol("glShaderSource")
        _compileShader = try symbol("glCompileShader")
        unsafe _getShaderiv = unsafe try symbol("glGetShaderiv")
        unsafe _getShaderInfoLog = unsafe try symbol("glGetShaderInfoLog")
        _deleteShader = try symbol("glDeleteShader")
        _createProgram = try symbol("glCreateProgram")
        _attachShader = try symbol("glAttachShader")
        unsafe _bindAttribLocation = unsafe try symbol("glBindAttribLocation")
        _linkProgram = try symbol("glLinkProgram")
        unsafe _getProgramiv = unsafe try symbol("glGetProgramiv")
        unsafe _getProgramInfoLog = unsafe try symbol("glGetProgramInfoLog")
        _useProgram = try symbol("glUseProgram")
        _deleteProgram = try symbol("glDeleteProgram")
        unsafe _getUniformLocation = unsafe try symbol("glGetUniformLocation")
        unsafe _getActiveUniform = unsafe try symbol("glGetActiveUniform")
        _uniform1i = try symbol("glUniform1i")
        unsafe _uniform1fv = unsafe try symbol("glUniform1fv")
        unsafe _uniform2fv = unsafe try symbol("glUniform2fv")
        unsafe _uniform3fv = unsafe try symbol("glUniform3fv")
        unsafe _uniform4fv = unsafe try symbol("glUniform4fv")
        unsafe _uniformMatrix3fv = unsafe try symbol("glUniformMatrix3fv")
        unsafe _uniformMatrix4fv = unsafe try symbol("glUniformMatrix4fv")
        unsafe _genVertexArrays = unsafe try symbol("glGenVertexArrays")
        unsafe _deleteVertexArrays = unsafe try symbol("glDeleteVertexArrays")
        _bindVertexArray = try symbol("glBindVertexArray")
        unsafe _genBuffers = unsafe try symbol("glGenBuffers")
        unsafe _deleteBuffers = unsafe try symbol("glDeleteBuffers")
        _bindBuffer = try symbol("glBindBuffer")
        unsafe _bufferData = unsafe try symbol("glBufferData")
        unsafe _vertexAttribPointer = unsafe try symbol("glVertexAttribPointer")
        _enableVertexAttribArray = try symbol("glEnableVertexAttribArray")
        _vertexAttribDivisor = try symbol("glVertexAttribDivisor")
        _drawArrays = try symbol("glDrawArrays")
        _drawArraysInstanced = try symbol("glDrawArraysInstanced")
        unsafe _choosePixelFormat = unsafe try symbol("CGLChoosePixelFormat")
        unsafe _createContext = unsafe try symbol("CGLCreateContext")
        unsafe _setCurrentContext = unsafe try symbol("CGLSetCurrentContext")
        unsafe _destroyContext = unsafe try symbol("CGLDestroyContext")
        unsafe _destroyPixelFormat = unsafe try symbol("CGLDestroyPixelFormat")
    }

    // MARK: - Context

    /// An offscreen 4.1 core context. It has no drawable: everything renders into
    /// framebuffer objects and is read back.
    @safe
    final class Context {
        private let gl: GL
        private let context: OpaquePointer

        init(gl: GL) throws {
            self.gl = gl
            let attributes: [UInt32] = [
                99, 0x4100, // kCGLPFAOpenGLProfile, kCGLOGLPVersion_GL4_Core
                73, // kCGLPFAAccelerated
                96, // kCGLPFAAllowOfflineRenderers
                8, 24, // kCGLPFAColorSize
                11, 8, // kCGLPFAAlphaSize
                0,
            ]
            var pixelFormat: OpaquePointer?
            var count: Int32 = 0
            let chooseError = attributes.withUnsafeBufferPointer { buffer in
                unsafe gl._choosePixelFormat(buffer.baseAddress!, &pixelFormat, &count)
            }
            guard chooseError == 0, let pixelFormat = unsafe pixelFormat else {
                throw GLError.contextCreation(chooseError)
            }
            defer { _ = unsafe gl._destroyPixelFormat(pixelFormat) }
            var context: OpaquePointer?
            let createError = unsafe gl._createContext(pixelFormat, nil, &context)
            guard createError == 0, let context = unsafe context else {
                throw GLError.contextCreation(createError)
            }
            unsafe self.context = context
        }

        /// Make this context current on the calling thread. Every GL call after
        /// this must stay on that thread.
        func makeCurrent() {
            _ = unsafe gl._setCurrentContext(context)
        }

        deinit {
            _ = gl._setCurrentContext(nil)
            _ = unsafe gl._destroyContext(context)
        }
    }

    // MARK: - State

    enum Blending {
        case none
        case translucent
        case additive

        /// A material's `blending` value.
        init(material mode: String) {
            switch mode {
            case "additive": self = .additive
            case "normal", "disabled": self = .none
            default: self = .translucent
            }
        }
    }

    func blend(_ blending: Blending) {
        switch blending {
        case .none:
            _disable(GLConst.blend)
        case .translucent:
            _enable(GLConst.blend)
            _blendFuncSeparate(GLConst.srcAlpha, GLConst.oneMinusSrcAlpha, GLConst.one, GLConst.oneMinusSrcAlpha)
        case .additive:
            _enable(GLConst.blend)
            _blendFuncSeparate(GLConst.srcAlpha, GLConst.one, GLConst.zero, GLConst.one)
        }
    }

    func viewport(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        _viewport(Int32(x), Int32(y), Int32(width), Int32(height))
    }

    func clear(red: Float, green: Float, blue: Float, alpha: Float) {
        _clearColor(red, green, blue, alpha)
        _clear(GLConst.colorBufferBit)
    }

    func disable(_ capability: Enum) {
        _disable(capability)
    }

    func pixelStore(_ name: Enum, _ value: Int) {
        _pixelStorei(name, Int32(value))
    }

    // MARK: - Textures

    func genTexture() -> UInt32 {
        var name: UInt32 = 0
        unsafe _genTextures(1, &name)
        return name
    }

    func deleteTexture(_ name: UInt32) {
        var name = name
        unsafe _deleteTextures(1, &name)
    }

    /// Bind `name` to texture unit `unit`, one of the ``WELimit/textureSlots``.
    func bindTexture(_ name: UInt32, unit: Int = 0) {
        guard (0 ..< WELimit.textureSlots).contains(unit) else { return }
        _activeTexture(GLConst.texture0 + UInt32(unit))
        _bindTexture(GLConst.texture2D, name)
    }

    // swiftlint:disable:next function_parameter_count
    func texImage2D(
        level: Int, internalFormat: UInt32, width: Int, height: Int, format: Enum, type: Enum,
        data: UnsafeRawPointer?,
    ) {
        unsafe _texImage2D(
            GLConst.texture2D, Int32(level), Int32(internalFormat), Int32(width), Int32(height), 0,
            format, type, data,
        )
    }

    func compressedTexImage2D(level: Int, format: Enum, width: Int, height: Int, data: UnsafeRawBufferPointer) {
        unsafe _compressedTexImage2D(
            GLConst.texture2D, Int32(level), format, Int32(width), Int32(height), 0,
            Int32(data.count), data.baseAddress,
        )
    }

    func texParameter(_ name: Enum, _ value: Int32) {
        _texParameteri(GLConst.texture2D, name, value)
    }

    // MARK: - Framebuffers

    func genFramebuffer() -> UInt32 {
        var name: UInt32 = 0
        unsafe _genFramebuffers(1, &name)
        return name
    }

    func deleteFramebuffer(_ name: UInt32) {
        var name = name
        unsafe _deleteFramebuffers(1, &name)
    }

    func bindFramebuffer(_ name: UInt32, target: Enum = GLConst.framebuffer) {
        _bindFramebuffer(target, name)
    }

    func attachTexture(_ texture: UInt32) -> Enum {
        _framebufferTexture2D(GLConst.framebuffer, GLConst.colorAttachment0, GLConst.texture2D, texture, 0)
        return _checkFramebufferStatus(GLConst.framebuffer)
    }

    func readPixels(width: Int, height: Int, format: Enum, type: Enum, into buffer: UnsafeMutableRawPointer) {
        unsafe _readPixels(0, 0, Int32(width), Int32(height), format, type, buffer)
    }

    /// Copy `src` of the read framebuffer onto `dst` of the draw framebuffer.
    func blitFramebuffer(
        src: (x0: Int, y0: Int, x1: Int, y1: Int), dst: (x0: Int, y0: Int, x1: Int, y1: Int), linear: Bool,
    ) {
        _blitFramebuffer(
            Int32(src.x0), Int32(src.y0), Int32(src.x1), Int32(src.y1),
            Int32(dst.x0), Int32(dst.y0), Int32(dst.x1), Int32(dst.y1),
            GLConst.colorBufferBit, UInt32(linear ? GLConst.linear : GLConst.nearest),
        )
    }

    // MARK: - Programs

    /// Compile and link a program. Attribute 0 is `a_Position`, 1 is `a_TexCoord`;
    /// any further names are bound in order after them.
    func makeProgram(vertex: String, fragment: String, attributes: [String] = []) throws -> UInt32 {
        let vs = try compile(vertex, kind: GLConst.vertexShader)
        defer { _deleteShader(vs) }
        let fs = try compile(fragment, kind: GLConst.fragmentShader)
        defer { _deleteShader(fs) }
        let program = _createProgram()
        _attachShader(program, vs)
        _attachShader(program, fs)
        for (index, name) in (["a_Position", "a_TexCoord"] + attributes).enumerated() {
            name.withCString { unsafe _bindAttribLocation(program, UInt32(index), $0) }
        }
        _linkProgram(program)
        var status: Int32 = 0
        unsafe _getProgramiv(program, GLConst.linkStatus, &status)
        guard status != 0 else {
            let log = unsafe infoLog(program, getter: _getProgramiv, logger: _getProgramInfoLog)
            _deleteProgram(program)
            throw GLError.shader(log)
        }
        return program
    }

    private func compile(_ source: String, kind: Enum) throws -> UInt32 {
        let shader = _createShader(kind)
        source.withCString { cString in
            var pointer: UnsafePointer<CChar>? = unsafe cString
            unsafe _shaderSource(shader, 1, &pointer, nil)
        }
        _compileShader(shader)
        var status: Int32 = 0
        unsafe _getShaderiv(shader, GLConst.compileStatus, &status)
        guard status != 0 else {
            let log = unsafe infoLog(shader, getter: _getShaderiv, logger: _getShaderInfoLog)
            _deleteShader(shader)
            throw GLError.shader(log)
        }
        return shader
    }

    private func infoLog(_ object: UInt32, getter: FnGetiv, logger: FnInfoLog) -> String {
        var length: Int32 = 0
        unsafe getter(object, GLConst.infoLogLength, &length)
        guard length > 1 else { return "" }
        var buffer = [CChar](repeating: 0, count: Int(length))
        buffer.withUnsafeMutableBufferPointer { unsafe logger(object, length, nil, $0.baseAddress!) }
        return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
    }

    func useProgram(_ program: UInt32) {
        _useProgram(program)
    }

    func deleteProgram(_ program: UInt32) {
        _deleteProgram(program)
    }

    struct ActiveUniform {
        let name: String
        let location: Int32
        let type: Enum
    }

    /// Every active uniform of a linked program. Array uniforms are reported by
    /// their base name (`g_Lights` for `g_Lights[0]`).
    func activeUniforms(_ program: UInt32) -> [ActiveUniform] {
        var count: Int32 = 0
        unsafe _getProgramiv(program, GLConst.activeUniforms, &count)
        var result: [ActiveUniform] = []
        for index in 0 ..< UInt32(max(count, 0)) {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            var length: Int32 = 0
            var size: Int32 = 0
            var type: Enum = 0
            nameBuffer.withUnsafeMutableBufferPointer { buffer in
                unsafe _getActiveUniform(program, index, 256, &length, &size, &type, buffer.baseAddress!)
            }
            let raw = String(bytes: nameBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
            let location = raw.withCString { unsafe _getUniformLocation(program, $0) }
            let name = raw.hasSuffix("[0]") ? String(raw.dropLast(3)) : raw
            result.append(ActiveUniform(name: name, location: location, type: type))
        }
        return result
    }

    func uniform(_ location: Int32, int value: Int32) {
        _uniform1i(location, value)
    }

    /// Upload `values` for a uniform of `type`, as many elements as the values fill.
    func uniform(_ location: Int32, type: Enum, values: [Float]) {
        guard !values.isEmpty else { return }
        values.withUnsafeBufferPointer { buffer in
            let pointer = buffer.baseAddress!
            switch type {
            case GLConst.typeVec2: unsafe _uniform2fv(location, Int32(values.count / 2), pointer)
            case GLConst.typeVec3: unsafe _uniform3fv(location, Int32(values.count / 3), pointer)
            case GLConst.typeVec4: unsafe _uniform4fv(location, Int32(values.count / 4), pointer)
            case GLConst.typeMat3: unsafe _uniformMatrix3fv(location, Int32(values.count / 9), 0, pointer)
            case GLConst.typeMat4: unsafe _uniformMatrix4fv(location, Int32(values.count / 16), 0, pointer)
            case GLConst.typeInt, GLConst.typeBool:
                _uniform1i(location, Int32(Int(clamping: values[0], to: Int(Int32.min) ... Int(Int32.max))))
            default: unsafe _uniform1fv(location, Int32(values.count), pointer)
            }
        }
    }

    // MARK: - Geometry

    func genVertexArray() -> UInt32 {
        var name: UInt32 = 0
        unsafe _genVertexArrays(1, &name)
        return name
    }

    func deleteVertexArray(_ name: UInt32) {
        var name = name
        unsafe _deleteVertexArrays(1, &name)
    }

    func bindVertexArray(_ name: UInt32) {
        _bindVertexArray(name)
    }

    func genBuffer() -> UInt32 {
        var name: UInt32 = 0
        unsafe _genBuffers(1, &name)
        return name
    }

    func deleteBuffer(_ name: UInt32) {
        var name = name
        unsafe _deleteBuffers(1, &name)
    }

    func bufferData(_ buffer: UInt32, floats: [Float], usage: Enum = GLConst.streamDraw) {
        _bindBuffer(GLConst.arrayBuffer, buffer)
        floats.withUnsafeBytes { bytes in
            unsafe _bufferData(GLConst.arrayBuffer, bytes.count, bytes.baseAddress, usage)
        }
    }

    /// Describe attribute `index` as `components` floats at `offset` within a
    /// `stride`-float record of the currently bound buffer.
    func vertexAttribute(_ index: UInt32, components: Int, stride: Int, offset: Int, divisor: UInt32 = 0) {
        let byteOffset = unsafe UnsafeRawPointer(bitPattern: offset * MemoryLayout<Float>.size)
        unsafe _vertexAttribPointer(
            index, Int32(components), GLConst.float, 0, Int32(stride * MemoryLayout<Float>.size), byteOffset,
        )
        _enableVertexAttribArray(index)
        _vertexAttribDivisor(index, divisor)
    }

    func drawArrays(_ mode: Enum, count: Int) {
        _drawArrays(mode, 0, Int32(count))
    }

    func drawArraysInstanced(_ mode: Enum, count: Int, instances: Int) {
        _drawArraysInstanced(mode, 0, Int32(count), Int32(instances))
    }
}

/// A linked program with its uniforms by name, for the renderer's own shaders.
nonisolated struct GLProgram {
    let name: UInt32
    private let gl: GL
    private let locations: [String: Int32]

    init(gl: GL, vertex: String, fragment: String, attributes: [String] = []) throws {
        self.gl = gl
        name = try gl.makeProgram(vertex: vertex, fragment: fragment, attributes: attributes)
        locations = Dictionary(uniqueKeysWithValues: gl.activeUniforms(name).map { ($0.name, $0.location) })
    }

    func use() {
        gl.useProgram(name)
    }

    /// Set a uniform the shader keeps; one the compiler dropped is skipped.
    func set(_ uniform: String, int value: Int32) {
        if let location = locations[uniform] {
            gl.uniform(location, int: value)
        }
    }

    func set(_ uniform: String, floats values: [Float], type: GL.Enum) {
        if let location = locations[uniform] {
            gl.uniform(location, type: type, values: values)
        }
    }

    func delete() {
        gl.deleteProgram(name)
    }
}
