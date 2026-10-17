import CoreVideo
import Foundation
import os

nonisolated let weLog = Logger(subsystem: "glass.kagerou.phosphene", category: "WallpaperEngine")

/// Draws a ``WEScene`` offscreen, one frame per call, at an output size.
///
/// Conventions, held everywhere so nothing needs flipping: every buffer stores the
/// image's top row at row 0, and texture coordinate (0, 0) is the top-left, as in
/// Direct3D, whose conventions Wallpaper Engine's shaders assume. The scene is laid
/// out in its own units (y up) and scaled to cover the output, then center-cropped,
/// the way Wallpaper Engine fills a screen of another shape.
final nonisolated class WERenderer {
    /// Widest layer buffer, in pixels.
    static let maxLayerPixels = 8_192
    /// Bytes all render targets of one scene may hold together.
    static let targetByteBudget = 2 << 30

    let outputWidth: Int
    let outputHeight: Int
    private let gl: GL
    private let files: WEFileSystem
    private let scene: WEScene
    /// The scene's layers, minus effects whose shaders would not compile.
    private var layers: [WEScene.Layer]
    /// What was left out and why, for the user: scene features plus dropped effects.
    private(set) var omissions: [String] = []
    private let programs: WEProgramCache
    private let textures: WETextureCache
    private let sceneTarget: WERenderTarget
    private let outputTarget: WERenderTarget
    private let scale: Float
    private let quadVertexArray: UInt32
    private let quadBuffer: UInt32
    private let composite: GLProgram
    private var blendPrograms: [Int: GLProgram?] = [:]
    /// Ping-pong pairs by size: a layer's buffers are only live while it is drawn,
    /// so layers of one size share a pair.
    private var layerTargets: [SIMD2<Int>: (WERenderTarget, WERenderTarget)] = [:]
    private var namedBuffers: [String: WERenderTarget] = [:]
    private var targetBytes = 0
    /// Each particle layer's simulation, with a copy for the early side of a crossfade.
    private var particles: [Int: (main: WEParticleSystem, early: WEParticleSystem)] = [:]
    private var crossfadeTarget: WERenderTarget?
    private let particleRenderer: WEParticleRenderer

    /// Frame interval the particle simulation steps by.
    var frameDuration: Double = 1.0 / 30

    init(gl: GL, files: WEFileSystem, scene: WEScene, width: Int, height: Int, scratch: URL) throws {
        self.gl = gl
        self.files = files
        self.scene = scene
        layers = scene.layers
        outputWidth = width
        outputHeight = height
        programs = WEProgramCache(gl: gl, files: files)
        textures = WETextureCache(gl: gl, files: files, scratch: scratch)
        scale = max(Float(width) / scene.size.x, Float(height) / scene.size.y)
        sceneTarget = try WERenderTarget(
            gl: gl,
            width: Int(clamping: (scene.size.x * scale).rounded(.up), to: 1 ... WELimit.dimension),
            height: Int(clamping: (scene.size.y * scale).rounded(.up), to: 1 ... WELimit.dimension),
        )
        outputTarget = try WERenderTarget(gl: gl, width: width, height: height)
        targetBytes = sceneTarget.byteCount + outputTarget.byteCount
        quadVertexArray = gl.genVertexArray()
        quadBuffer = gl.genBuffer()
        gl.bindVertexArray(quadVertexArray)
        gl.bufferData(quadBuffer, floats: Array(repeating: 0, count: 20))
        gl.vertexAttribute(0, components: 3, stride: 5, offset: 0)
        gl.vertexAttribute(1, components: 2, stride: 5, offset: 3)
        composite = try GLProgram(gl: gl, vertex: Self.compositeVertex, fragment: Self.compositeFragment)
        particleRenderer = try WEParticleRenderer(gl: gl)
        gl.disable(GLConst.depthTest)
        gl.disable(GLConst.cullFace)

        for (index, layer) in scene.layers.enumerated() {
            if case let .particles(definition) = layer {
                particles[index] = (
                    WEParticleSystem(layer: definition, seed: UInt64(index + 1)),
                    WEParticleSystem(layer: definition, seed: UInt64(index + 1)),
                )
            }
        }
        try prepare()
    }

    /// Compile every program and load every texture up front, so a broken wallpaper
    /// fails before any frame is encoded. An effect whose shader will not compile is
    /// dropped (its layer draws without it); a layer whose own image will not draw
    /// fails the render.
    private func prepare() throws {
        for (index, layer) in layers.enumerated() {
            switch layer {
            case var .image(image):
                if !image.copiesBackground {
                    _ = try program(for: image.base, slotFormats: slotFormats(image.base), sprite: isSprite(image.base))
                }
                image.effects = image.effects.filter { effect in
                    do {
                        for pass in effect.passes {
                            _ = try program(for: pass, slotFormats: slotFormats(pass, buffers: effect.buffers), sprite: false)
                        }
                        return true
                    } catch {
                        let name = effect.passes.first.map { ($0.shader as NSString).lastPathComponent } ?? "effect"
                        weLog.error("Dropping effect \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        omissions.append("the “\(name)” effect")
                        return false
                    }
                }
                layers[index] = .image(image)
            case let .particles(layer):
                _ = textures.texture(layer.material.textures.first.flatMap(\.self) ?? "")
            }
        }
        for (feature, count) in scene.skipped.sorted(by: { $0.key < $1.key }) {
            omissions.append(count > 1 ? "\(feature) (\(count))" : feature)
        }
    }

    func release() {
        programs.deleteAll()
        textures.deleteAll()
        for (first, second) in layerTargets.values {
            first.delete(gl)
            second.delete(gl)
        }
        for buffer in namedBuffers.values {
            buffer.delete(gl)
        }
        sceneTarget.delete(gl)
        outputTarget.delete(gl)
        crossfadeTarget?.delete(gl)
        composite.delete()
        for program in blendPrograms.values.compactMap(\.self) {
            program.delete()
        }
        gl.deleteVertexArray(quadVertexArray)
        gl.deleteBuffer(quadBuffer)
        particleRenderer.release()
    }

    // MARK: - Frame

    /// Draw the scene at `time` seconds into the output buffer.
    ///
    /// Particle systems are simulations: they advance by ``frameDuration`` per call,
    /// so calls must come in time order. Use ``resetSimulation(to:)`` to jump.
    func render(time: Double) throws {
        try render(time: time, early: false)
    }

    /// Draw `late` (main simulation) and `early` (secondary simulation) and mix them,
    /// `weight` 0 being all `late`.
    func renderCrossfade(late: Double, early: Double, weight: Float) throws {
        try render(time: late, early: false)
        let target: WERenderTarget
        if let existing = crossfadeTarget {
            target = existing
        } else {
            target = try makeTarget(width: outputWidth, height: outputHeight)
            crossfadeTarget = target
        }
        copy(outputTarget, to: target)
        try render(time: early, early: true)
        outputTarget.bind(gl)
        gl.blend(.translucent)
        draw(composite, texture: target.texture, alpha: 1 - weight, vertices: Self.fullQuad(extent: SIMD2(1, 1)))
    }

    /// Restart particle simulations so the next frame is `time`.
    func resetSimulation(to time: Double) {
        for (system, _) in particles.values {
            system.reset(to: time)
            system.step(to: time, frame: frameDuration)
        }
    }

    /// Restart the secondary simulations at `time`.
    func resetSecondarySimulation(to time: Double) {
        for (_, system) in particles.values {
            system.reset(to: time)
            system.step(to: time, frame: frameDuration)
        }
    }

    private func render(time: Double, early: Bool) throws {
        textures.advanceVideos(to: time, stream: early ? 1 : 0)
        sceneTarget.bind(gl)
        let clear = scene.clearColor
        gl.clear(red: clear.x, green: clear.y, blue: clear.z, alpha: 1)

        for (index, layer) in layers.enumerated() {
            switch layer {
            case let .image(image):
                try draw(image, index: index, time: time)
            case let .particles(definition):
                guard let pair = particles[index] else { continue }
                let system = early ? pair.early : pair.main
                if !system.isPrimed {
                    system.reset(to: time)
                }
                system.step(to: time, frame: frameDuration)
                try drawParticles(system, layer: definition)
            }
        }

        let cropX = (sceneTarget.width - outputWidth) / 2
        let cropY = (sceneTarget.height - outputHeight) / 2
        copy(sceneTarget, rect: (cropX, cropY, cropX + outputWidth, cropY + outputHeight), to: outputTarget)
    }

    var hasParticles: Bool {
        !particles.isEmpty
    }

    var videoDurations: [Double] {
        textures.videos.map(\.duration)
    }

    /// Copy the output into a 32BGRA pixel buffer of at least the output size.
    func read(into pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetWidth(pixelBuffer) >= outputWidth, CVPixelBufferGetHeight(pixelBuffer) >= outputHeight
        else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        gl.bindFramebuffer(outputTarget.framebuffer, target: GLConst.readFramebuffer)
        gl.pixelStore(GLConst.packAlignment, 4)
        gl.pixelStore(GLConst.packRowLength, CVPixelBufferGetBytesPerRow(pixelBuffer) / 4)
        if let base = unsafe CVPixelBufferGetBaseAddress(pixelBuffer) {
            unsafe gl.readPixels(
                width: outputWidth, height: outputHeight, format: GLConst.bgra, type: GLConst.unsignedInt8888Rev,
                into: base,
            )
        }
        gl.pixelStore(GLConst.packRowLength, 0)
    }

    /// The output as tightly packed BGRA bytes, top row first.
    func readBGRA() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
        gl.bindFramebuffer(outputTarget.framebuffer, target: GLConst.readFramebuffer)
        gl.pixelStore(GLConst.packAlignment, 1)
        bytes.withUnsafeMutableBytes { buffer in
            unsafe gl.readPixels(
                width: outputWidth, height: outputHeight, format: GLConst.bgra, type: GLConst.unsignedInt8888Rev,
                into: buffer.baseAddress!,
            )
        }
        return bytes
    }

    // MARK: - Buffers

    private func makeTarget(width: Int, height: Int) throws -> WERenderTarget {
        let target = try WERenderTarget(gl: gl, width: width, height: height)
        targetBytes += target.byteCount
        guard targetBytes <= Self.targetByteBudget else {
            throw WEError.unsupported("more than \(Self.targetByteBudget >> 20) MB of layer buffers")
        }
        return target
    }

    private func targets(for size: SIMD2<Int>) throws -> (WERenderTarget, WERenderTarget) {
        if let existing = layerTargets[size] {
            return existing
        }
        let pair = try (makeTarget(width: size.x, height: size.y), makeTarget(width: size.x, height: size.y))
        layerTargets[size] = pair
        return pair
    }

    private func namedBuffer(_ key: String, width: Int, height: Int) throws -> WERenderTarget {
        if let existing = namedBuffers[key] {
            return existing
        }
        let target = try makeTarget(width: width, height: height)
        namedBuffers[key] = target
        return target
    }

    /// Copy `rect` of `source` (all of it by default) onto all of `destination`.
    private func copy(
        _ source: WERenderTarget, rect: (x0: Int, y0: Int, x1: Int, y1: Int)? = nil, to destination: WERenderTarget,
        linear: Bool = false,
    ) {
        gl.bindFramebuffer(source.framebuffer, target: GLConst.readFramebuffer)
        gl.bindFramebuffer(destination.framebuffer, target: GLConst.drawFramebuffer)
        gl.blitFramebuffer(
            src: rect ?? (0, 0, source.width, source.height), dst: (0, 0, destination.width, destination.height),
            linear: linear,
        )
    }

    /// The scene drawn so far, for a pass that samples it while drawing onto it.
    private func sceneSnapshot() throws -> WERenderTarget {
        let background = try namedBuffer("background", width: sceneTarget.width, height: sceneTarget.height)
        copy(sceneTarget, to: background)
        return background
    }

    // MARK: - Particles

    private func drawParticles(_ system: WEParticleSystem, layer: WEScene.ParticleLayer) throws {
        let material = layer.material
        var refraction: WEParticleRenderer.Refraction?
        if material.combos["REFRACT"] ?? 0 != 0, material.textures.count > 1, let normalName = material.textures[1] {
            let background = try sceneSnapshot()
            refraction = .init(
                normalMap: textures.texture(normalName), background: background.texture,
                amount: WEJSON.float(Self.constant("ui_editor_properties_refract_amount", in: material.constants), default: 0.05),
            )
        }
        sceneTarget.bind(gl)
        particleRenderer.draw(
            system, layer: layer, texture: textures.texture(material.textures.first.flatMap(\.self) ?? "util/white"),
            sceneSize: scene.size, refraction: refraction,
            overbright: WEJSON.float(Self.constant("ui_editor_properties_overbright", in: material.constants), default: 1),
        )
    }

    // MARK: - Image layers

    private struct Bound {
        let texture: UInt32
        let resolution: SIMD4<Float>
        var formatCode = 0

        init(_ target: WERenderTarget) {
            texture = target.texture
            resolution = target.resolution
        }

        init(_ texture: WEGLTexture) {
            self.texture = texture.name
            resolution = texture.resolution
            formatCode = texture.formatCode
        }
    }

    private func draw(_ layer: WEScene.ImageLayer, index: Int, time: Double) throws {
        let pixelSize = SIMD2<Int>(
            Int(clamping: layer.size.x * scale, to: 1 ... Self.maxLayerPixels),
            Int(clamping: layer.size.y * scale, to: 1 ... Self.maxLayerPixels),
        )
        var (previous, spare) = try targets(for: pixelSize)

        // Base: the layer's image through its material, or the scene beneath it.
        previous.bind(gl)
        gl.clear(red: 0, green: 0, blue: 0, alpha: 0)
        gl.blend(.none)
        if layer.copiesBackground {
            copy(sceneTarget, rect: sceneRect(of: layer), to: previous, linear: true)
        } else {
            try drawBase(layer, into: previous, time: time)
        }

        for (effectIndex, effect) in layer.effects.enumerated() {
            try apply(effect, key: "\(index)/\(effectIndex)", size: pixelSize, previous: &previous, spare: &spare, time: time)
        }

        // Composite onto the scene. Blend modes read what is beneath: a copy of the
        // scene so far.
        let alpha = layer.copiesBackground ? layer.alpha.value(at: time) : 1
        let vertices = compositeVertices(for: layer)
        if layer.blendMode != 0, let program = blendCompositeProgram(layer.blendMode) {
            let background = try sceneSnapshot()
            sceneTarget.bind(gl)
            gl.blend(.none)
            draw(program, texture: previous.texture, background: background.texture, alpha: alpha, vertices: vertices)
        } else {
            sceneTarget.bind(gl)
            gl.blend(GL.Blending(material: layer.base.blending))
            draw(composite, texture: previous.texture, alpha: alpha, vertices: vertices)
        }
    }

    /// Run an effect's passes over the layer: they ping-pong between `previous` and
    /// `spare`, leaving the result in `previous`. Named buffers are scoped to the
    /// effect instance by `key`.
    private func apply(
        _ effect: WEScene.Effect, key: String, size: SIMD2<Int>, previous: inout WERenderTarget,
        spare: inout WERenderTarget, time: Double,
    ) throws {
        var named: [String: WERenderTarget] = [:]
        for (name, divisor) in effect.buffers {
            named[name] = try namedBuffer(
                "\(key)/\(name)", width: max(1, size.x / divisor), height: max(1, size.y / divisor),
            )
        }
        for pass in effect.passes {
            let output = pass.target.flatMap { named[$0] } ?? spare
            var slots: [Int: Bound] = [:]
            for (slot, name) in pass.textures.enumerated() {
                guard let name else { continue }
                if let buffer = named[name] {
                    slots[slot] = Bound(buffer)
                } else if name.hasPrefix("_rt_") {
                    slots[slot] = Bound(sceneTarget)
                } else {
                    slots[slot] = Bound(textures.texture(name))
                }
            }
            for bind in pass.binds {
                if let buffer = bind.name == "previous" ? previous : named[bind.name] {
                    slots[bind.slot] = Bound(buffer)
                }
            }
            if slots[0] == nil {
                slots[0] = Bound(previous)
            }
            let program = try program(for: pass, slotFormats: slots.mapValues(\.formatCode), sprite: false)
            output.bind(gl)
            gl.blend(.none)
            draw(
                program, pass: pass, slots: slots, target: output, layer: nil, time: time,
                vertices: Self.fullQuad(extent: SIMD2(1, 1)), sprite: nil,
            )
            if pass.target == nil {
                swap(&previous, &spare)
            }
        }
    }

    /// Draw `texture` (over `background`, for a blend-mode program) with a composite program.
    private func draw(_ program: GLProgram, texture: UInt32, background: UInt32? = nil, alpha: Float, vertices: [Float]) {
        program.use()
        gl.bindTexture(texture, unit: 0)
        program.set("u_Texture", int: 0)
        if let background {
            gl.bindTexture(background, unit: 1)
            program.set("u_Background", int: 1)
        }
        program.set("u_Alpha", floats: [alpha], type: GLConst.typeFloat)
        drawQuad(vertices)
    }

    /// A composite program for a `colorBlendMode`, built on the install's own
    /// `common_blending.h`; `nil` (normal blending) when that header is missing.
    private func blendCompositeProgram(_ mode: Int) -> GLProgram? {
        if let cached = blendPrograms[mode] {
            return cached
        }
        var result: GLProgram?
        if let header = files.text("shaders/common_blending.h") {
            let fragment = """
            #version 410
            #define GLSL 1
            #define BLENDMODE \(mode)
            \(WEShaderSource.prelude)
            \(header)
            in vec2 v_UV;
            in vec2 v_Screen;
            uniform sampler2D u_Texture;
            uniform sampler2D u_Background;
            uniform float u_Alpha;
            out vec4 o_Color;
            void main() {
                vec4 color = texture(u_Texture, v_UV);
                vec4 below = texture(u_Background, v_Screen);
                o_Color = vec4(ApplyBlending(BLENDMODE, below.rgb, color.rgb, color.a * u_Alpha), below.a);
            }
            """
            do {
                result = try GLProgram(gl: gl, vertex: Self.blendVertex, fragment: fragment)
            } catch {
                weLog.error("Blend mode \(mode) unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        blendPrograms[mode] = result
        return result
    }

    private func drawBase(_ layer: WEScene.ImageLayer, into target: WERenderTarget, time: Double) throws {
        var slots: [Int: Bound] = [:]
        var baseTexture: WEGLTexture?
        for (slot, name) in layer.base.textures.enumerated() {
            guard let name else { continue }
            let texture = textures.texture(name)
            if slot == 0 {
                baseTexture = texture
            }
            slots[slot] = Bound(texture)
        }
        let sprite = baseTexture.flatMap { texture in spriteFrame(of: texture, at: time).map { ($0, texture.resolution) } }
        let program = try program(for: layer.base, slotFormats: slots.mapValues(\.formatCode), sprite: sprite != nil)
        let extent = sprite == nil ? (baseTexture?.imageExtent ?? SIMD2(1, 1)) : SIMD2(1, 1)
        draw(
            program, pass: layer.base, slots: slots, target: target, layer: layer, time: time,
            vertices: Self.fullQuad(extent: extent), sprite: sprite,
        )
    }

    /// The layer's axis-aligned rectangle in scene-buffer pixels, rows from the top.
    private func sceneRect(of layer: WEScene.ImageLayer) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let placement = layer.placement
        let half = layer.size * SIMD2(abs(placement.scale.x), abs(placement.scale.y)) / 2
        let left = (placement.origin.x - half.x) * scale
        let right = (placement.origin.x + half.x) * scale
        let top = (scene.size.y - (placement.origin.y + half.y)) * scale
        let bottom = (scene.size.y - (placement.origin.y - half.y)) * scale
        let columns = 0 ... sceneTarget.width
        let rows = 0 ... sceneTarget.height
        return (
            Int(clamping: left, to: columns), Int(clamping: top, to: rows),
            Int(clamping: right, to: columns), Int(clamping: bottom, to: rows),
        )
    }

    private func compositeVertices(for layer: WEScene.ImageLayer) -> [Float] {
        let placement = layer.placement
        let half = layer.size * placement.scale / 2
        let cosine = cos(placement.angle)
        let sine = sin(placement.angle)
        // Top-left, top-right, bottom-left, bottom-right with their texture coordinates.
        let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
            (SIMD2(-half.x, half.y), SIMD2(0, 0)), (SIMD2(half.x, half.y), SIMD2(1, 0)),
            (SIMD2(-half.x, -half.y), SIMD2(0, 1)), (SIMD2(half.x, -half.y), SIMD2(1, 1)),
        ]
        var vertices: [Float] = []
        for (local, uv) in corners {
            let rotated = SIMD2(local.x * cosine - local.y * sine, local.x * sine + local.y * cosine)
            let world = placement.origin + rotated
            vertices += [world.x / scene.size.x * 2 - 1, 1 - world.y / scene.size.y * 2, 0, uv.x, uv.y]
        }
        return vertices
    }

    /// A clip-space quad whose texture coordinates span `extent` with (0, 0) on row 0.
    private static func fullQuad(extent: SIMD2<Float>) -> [Float] {
        [
            -1, -1, 0, 0, 0,
            1, -1, 0, extent.x, 0,
            -1, 1, 0, 0, extent.y,
            1, 1, 0, extent.x, extent.y,
        ]
    }

    private func drawQuad(_ vertices: [Float]) {
        gl.bindVertexArray(quadVertexArray)
        gl.bufferData(quadBuffer, floats: vertices)
        gl.drawArrays(GLConst.triangleStrip, count: 4)
    }

    // MARK: - Passes

    private func isSprite(_ pass: WEScene.Pass) -> Bool {
        guard let name = pass.textures.first.flatMap(\.self) else { return false }
        return !textures.texture(name).spriteFrames.isEmpty
    }

    /// The format of each filled slot, as a draw of `pass` will fill them.
    private func slotFormats(_ pass: WEScene.Pass, buffers: [String: Int]? = nil) -> [Int: Int] {
        var formats: [Int: Int] = [:]
        for (slot, name) in pass.textures.enumerated() {
            guard let name else { continue }
            let isBuffer = name.hasPrefix("_rt_") || buffers?[name] != nil
            formats[slot] = isBuffer ? 0 : textures.texture(name).formatCode
        }
        for bind in pass.binds {
            formats[bind.slot] = 0
        }
        if buffers != nil, formats[0] == nil {
            formats[0] = 0
        }
        return formats
    }

    /// The program for `pass`: shader defaults, then the material's and scene's
    /// switches, then the switches sampler annotations tie to filled slots.
    private func program(for pass: WEScene.Pass, slotFormats: [Int: Int], sprite: Bool) throws -> WEProgram {
        let source = try programs.source(pass.shader)
        var combos = source.comboDefaults
        combos.merge(pass.combos) { _, new in new }
        for (uniform, annotation) in source.annotations {
            guard let combo = annotation.combo, let texture = Self.textureUniform(uniform), texture.suffix.isEmpty,
                  texture.slot > 0, slotFormats[texture.slot] != nil
            else { continue }
            combos[combo] = 1
        }
        for slot in source.formatSlots {
            combos["TEX\(slot)FORMAT"] = slotFormats[slot] ?? 0
        }
        if sprite {
            combos["SPRITESHEET"] = 1
        }
        return try programs.program(pass.shader, combos: combos)
    }

    /// `g_Texture3Resolution` → slot 3, suffix `Resolution`; the sampler itself has
    /// an empty suffix. Slots run `0 ..< WELimit.textureSlots`.
    private static func textureUniform(_ name: String) -> (slot: Int, suffix: Substring)? {
        guard name.hasPrefix("g_Texture") else { return nil }
        let rest = name.dropFirst("g_Texture".count)
        let digits = rest.prefix { $0.isNumber }
        guard let slot = Int(digits), (0 ..< WELimit.textureSlots).contains(slot) else { return nil }
        return (slot, rest.dropFirst(digits.count))
    }

    private func spriteFrame(of texture: WEGLTexture, at time: Double) -> WETexture.SpriteFrame? {
        let frames = texture.spriteFrames
        guard !frames.isEmpty else { return nil }
        let total = frames.reduce(Float(0)) { $0 + max($1.frameTime, 0) }
        guard total > 0 else { return frames[0] }
        var remaining = Float(time).truncatingRemainder(dividingBy: total)
        for frame in frames {
            remaining -= max(frame.frameTime, 0)
            if remaining < 0 {
                return frame
            }
        }
        return frames.last
    }

    // swiftlint:disable:next function_parameter_count
    private func draw(
        _ program: WEProgram, pass: WEScene.Pass, slots: [Int: Bound], target: WERenderTarget,
        layer: WEScene.ImageLayer?, time: Double, vertices: [Float],
        sprite: (frame: WETexture.SpriteFrame, resolution: SIMD4<Float>)?,
    ) {
        gl.useProgram(program.program)
        var bound = slots
        for uniform in program.uniforms where uniform.type == GLConst.typeSampler2D {
            guard let texture = Self.textureUniform(uniform.name), texture.suffix.isEmpty else { continue }
            gl.uniform(uniform.location, int: Int32(texture.slot))
            if bound[texture.slot] == nil {
                let fallback = program.source.annotations[uniform.name]?.defaultTexture.map {
                    textures.texture($0)
                } ?? textures.fallback
                bound[texture.slot] = Bound(fallback)
            }
        }
        for (slot, texture) in bound {
            gl.bindTexture(texture.texture, unit: slot)
        }
        let frame = Frame(target: target, time: time, layer: layer, sprite: sprite, bound: bound)
        for uniform in program.uniforms where uniform.type != GLConst.typeSampler2D {
            let values = builtinValue(of: uniform.name, in: frame)
                ?? program.source.annotations[uniform.name].flatMap { annotation in
                    annotation.materialKey.flatMap { Self.constant($0, in: pass.constants) }.flatMap { WEJSON.floats($0) }
                        ?? WEJSON.floats(annotation.defaultValue)
                }
            guard let values else { continue }
            gl.uniform(uniform.location, type: uniform.type, values: Self.fit(values, type: uniform.type))
        }
        drawQuad(vertices)
    }

    /// What one draw tells the built-in `g_…` uniforms.
    private struct Frame {
        let target: WERenderTarget
        let time: Double
        let layer: WEScene.ImageLayer?
        let sprite: (frame: WETexture.SpriteFrame, resolution: SIMD4<Float>)?
        let bound: [Int: Bound]
    }

    /// Built-in uniforms that never change: every transform is the identity, since
    /// the scene is drawn in its own units; there is no pointer, no eye and no clock.
    private static let fixedUniforms: [String: [Float]] = {
        let identity4: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        var values: [String: [Float]] = [
            "g_NormalModelMatrix": [1, 0, 0, 0, 1, 0, 0, 0, 1],
            "g_Daytime": [0.5],
            "g_PointerPosition": [0.5, 0.5], "g_PointerPositionLast": [0.5, 0.5], "g_ParallaxPosition": [0.5, 0.5],
            "g_EyePosition": [0, 0, 1],
        ]
        for matrix in [
            "g_ModelViewProjectionMatrix", "g_ModelMatrix", "g_ViewProjectionMatrix",
            "g_EffectTextureProjectionMatrix", "g_EffectTextureProjectionMatrixInverse",
            "g_ModelMatrixInverse", "g_EffectModelMatrix", "g_EffectModelViewProjectionMatrix",
            "g_EffectModelViewProjectionMatrixInverse",
        ] {
            values[matrix] = identity4
        }
        return values
    }()

    /// The value of a built-in uniform, `nil` for a name the material supplies.
    private func builtinValue(of name: String, in frame: Frame) -> [Float]? {
        if let fixed = Self.fixedUniforms[name] {
            return fixed
        }
        let width = Float(frame.target.width)
        let height = Float(frame.target.height)
        switch name {
        case "g_Time": return [Float(frame.time)]
        case "g_Frametime": return [Float(frameDuration)]
        case "g_TexelSize": return [1 / width, 1 / height]
        case "g_TexelSizeHalf": return [0.5 / width, 0.5 / height]
        case "g_Screen": return [Float(outputWidth), Float(outputHeight), Float(outputWidth) / Float(outputHeight)]
        default: break
        }
        if let texture = Self.textureUniform(name) {
            return textureValue(slot: texture.slot, suffix: texture.suffix, in: frame)
        }
        guard let layer = frame.layer else { return nil }
        switch name {
        case "g_Brightness": return [layer.brightness]
        case "g_UserAlpha", "g_Alpha": return [layer.alpha.value(at: frame.time)]
        case "g_Color": return [layer.color.x, layer.color.y, layer.color.z]
        case "g_Color4": return [layer.color.x, layer.color.y, layer.color.z, layer.alpha.value(at: frame.time)]
        default: return nil
        }
    }

    /// `g_TextureNResolution`, and the sprite frame's `Rotation`/`Translation` for slot 0.
    private func textureValue(slot: Int, suffix: Substring, in frame: Frame) -> [Float]? {
        switch suffix {
        case "Resolution":
            let resolution = frame.bound[slot]?.resolution ?? SIMD4(1, 1, 1, 1)
            return [resolution.x, resolution.y, resolution.z, resolution.w]
        case "Rotation":
            guard slot == 0, let sprite = frame.sprite else { return [1, 0, 0, 1] }
            let res = sprite.resolution
            return [sprite.frame.width / res.x, sprite.frame.widthY / res.y, sprite.frame.heightX / res.x, sprite.frame.height / res.y]
        case "Translation":
            guard slot == 0, let sprite = frame.sprite else { return [0, 0] }
            return [sprite.frame.x / sprite.resolution.x, sprite.frame.y / sprite.resolution.y]
        default:
            return nil
        }
    }

    private static func constant(_ key: String, in constants: [String: Any]) -> Any? {
        if let value = constants[key] {
            return value
        }
        let lowered = key.lowercased()
        return constants.first { $0.key.lowercased() == lowered }?.value
    }

    private static func fit(_ values: [Float], type: UInt32) -> [Float] {
        let needed = switch type {
        case GLConst.typeVec2: 2
        case GLConst.typeVec3: 3
        case GLConst.typeVec4: 4
        case GLConst.typeMat3: 9
        case GLConst.typeMat4: 16
        default: 1
        }
        if values.count >= needed {
            return Array(values.prefix(max(needed, values.count - values.count % needed)))
        }
        if values.count == 1 {
            return Array(repeating: values[0], count: needed)
        }
        return values + Array(repeating: 0, count: needed - values.count)
    }

    // MARK: - Composite shaders

    private static let compositeVertex = """
    #version 410
    in vec3 a_Position;
    in vec2 a_TexCoord;
    out vec2 v_UV;
    void main() {
        gl_Position = vec4(a_Position, 1.0);
        v_UV = a_TexCoord;
    }
    """

    private static let blendVertex = """
    #version 410
    in vec3 a_Position;
    in vec2 a_TexCoord;
    out vec2 v_UV;
    out vec2 v_Screen;
    void main() {
        gl_Position = vec4(a_Position, 1.0);
        v_UV = a_TexCoord;
        v_Screen = a_Position.xy * 0.5 + 0.5;
    }
    """

    private static let compositeFragment = """
    #version 410
    in vec2 v_UV;
    uniform sampler2D u_Texture;
    uniform float u_Alpha;
    out vec4 o_Color;
    void main() {
        vec4 color = texture(u_Texture, v_UV);
        o_Color = vec4(color.rgb, color.a * u_Alpha);
    }
    """
}
