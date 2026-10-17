import Foundation

/// The parts of a Wallpaper Engine `scene.json` that a 2D wallpaper draws with,
/// resolved into plain values: image layers with their effect chains, and particle
/// systems. Text, sound and 3D models are counted in ``skipped`` and left out.
nonisolated struct WEScene {
    /// A shader pass: which shader, its switches, textures by slot, and the
    /// constants its annotated uniforms read by material key.
    struct Pass {
        var shader: String
        var combos: [String: Int]
        /// At most ``WELimit/textureSlots`` entries.
        var textures: [String?]
        var constants: [String: Any]
        var blending: String
        /// Effect passes only: the named buffer drawn into (`nil` = the layer's next buffer).
        var target: String?
        /// Effect passes only: buffers bound by name to texture slots.
        var binds: [(name: String, slot: Int)]
    }

    struct Effect {
        var passes: [Pass]
        /// Named intermediate buffers and their downscale factor.
        var buffers: [String: Int]
    }

    /// Where an object sits in the scene: its center, scale and rotation.
    struct Placement {
        var origin: SIMD2<Float>
        var scale: SIMD2<Float>
        var angle: Float
    }

    struct ImageLayer {
        var name: String
        var placement: Placement
        var size: SIMD2<Float>
        var alpha: WEAnimatedValue
        var color: SIMD3<Float>
        var brightness: Float
        /// Wallpaper Engine's `colorBlendMode`: 0 is normal alpha blending, the rest
        /// are the Photoshop-style modes of `common_blending.h`.
        var blendMode: Int
        var base: Pass
        /// The layer shows what is already drawn beneath it (a fullscreen or compose
        /// layer), so its base is a copy of the scene rather than an image.
        var copiesBackground: Bool
        var effects: [Effect]
    }

    struct ParticleLayer {
        var name: String
        var placement: Placement
        var definition: [String: Any]
        var material: Pass
        var countMultiplier: Float
        var sizeMultiplier: Float
        var alphaMultiplier: Float
        var speedMultiplier: Float
        var lifetimeMultiplier: Float
        var rateMultiplier: Float
        var colorOverride: SIMD3<Float>?
    }

    enum Layer {
        case image(ImageLayer)
        case particles(ParticleLayer)
    }

    let size: SIMD2<Float>
    let clearColor: SIMD3<Float>
    let layers: [Layer]
    /// Feature name → how many objects used it and were not drawn.
    let skipped: [String: Int]
    /// Features without which the picture itself would be wrong, so the scene is
    /// not rendered at all (a puppet-warp character drawn flat shows its parts atlas).
    let blockers: [String]

    init(files: WEFileSystem, sceneFile: String, properties: [String: Any]) throws {
        guard let root = files.json(sceneFile) else { throw WEError.missing(sceneFile) }
        let general = root["general"] as? [String: Any] ?? [:]
        guard let ortho = general["orthogonalprojection"] as? [String: Any],
              let width = WEJSON.floats(ortho["width"])?.first,
              let height = WEJSON.floats(ortho["height"])?.first
        else { throw WEError.unsupported("a 3D camera") }
        // The scene buffer is this size times the output scale.
        guard (1 ... Float(WELimit.dimension)).contains(width), (1 ... Float(WELimit.dimension)).contains(height) else {
            throw WEError.malformed("scene size \(width) × \(height)")
        }
        size = SIMD2(width, height)
        let clear = WEJSON.vector(general["clearcolor"], count: 3, properties: properties, default: [0, 0, 0])
        clearColor = SIMD3(clear[0], clear[1], clear[2])

        var layers: [Layer] = []
        var skipped: [String: Int] = [:]
        var blockers = Set<String>()
        for object in root["objects"] as? [[String: Any]] ?? [] {
            guard WEJSON.bool(object["visible"], properties: properties, default: true) else { continue }
            if let image = object["image"] as? String {
                if files.json(image)?["puppet"] != nil {
                    blockers.insert("puppet-warp animation")
                }
                if let layer = Self.imageLayer(object, model: image, files: files, sceneSize: size, properties: properties) {
                    layers.append(.image(layer))
                }
            } else if let particle = object["particle"] as? String {
                if let layer = Self.particleLayer(object, file: particle, files: files, properties: properties) {
                    layers.append(.particles(layer))
                } else {
                    skipped["particles", default: 0] += 1
                }
            } else if object["text"] != nil {
                skipped["text", default: 0] += 1
            } else if object["sound"] != nil {
                skipped["sound", default: 0] += 1
            } else if object["model"] != nil {
                skipped["3D models", default: 0] += 1
            }
        }
        self.layers = layers
        self.skipped = skipped
        self.blockers = blockers.sorted()
    }

    private static func placement(of object: [String: Any], properties: [String: Any]) -> Placement {
        let origin = WEJSON.vector(object["origin"], count: 3, properties: properties, default: [0, 0, 0])
        let scale = WEJSON.vector(object["scale"], count: 3, properties: properties, default: [1, 1, 1])
        let angle = WEJSON.vector(object["angles"], count: 3, properties: properties, default: [0, 0, 0])[2]
        return Placement(origin: SIMD2(origin[0], origin[1]), scale: SIMD2(scale[0], scale[1]), angle: angle)
    }

    // MARK: - Image layers

    private static func imageLayer(
        _ object: [String: Any], model modelPath: String, files: WEFileSystem, sceneSize: SIMD2<Float>,
        properties: [String: Any],
    ) -> ImageLayer? {
        guard let model = files.json(modelPath),
              let materialPath = model["material"] as? String,
              var base = pass(fromMaterial: materialPath, files: files)
        else { return nil }
        let copiesBackground = base.textures.first.flatMap(\.self)?.hasPrefix("_rt_FullFrameBuffer") ?? false

        var size = WEJSON.vector(object["size"], count: 2, default: [0, 0])
        if size == [0, 0] {
            size = [
                WEJSON.float(model["width"], default: sceneSize.x), WEJSON.float(model["height"], default: sceneSize.y),
            ]
        }
        var placement = placement(of: object, properties: properties)
        if WEJSON.bool(model["fullscreen"], default: false) {
            size = [sceneSize.x, sceneSize.y]
            placement = Placement(origin: sceneSize / 2, scale: SIMD2(1, 1), angle: 0)
        }
        let color = WEJSON.vector(object["color"], count: 3, properties: properties, default: [1, 1, 1])

        // Object-level shader constants and switches apply to the base material.
        if let overrides = object["constantshadervalues"] as? [String: Any] {
            base.constants.merge(overrides) { _, new in new }
        }

        var effects: [Effect] = []
        for effectObject in (object["effects"] as? [[String: Any]] ?? []).prefix(WELimit.effectsPerLayer) {
            guard WEJSON.bool(effectObject["visible"], properties: properties, default: true),
                  let file = effectObject["file"] as? String,
                  let effect = Self.effect(file: file, overrides: effectObject, files: files)
            else { continue }
            effects.append(effect)
        }

        return ImageLayer(
            name: object["name"] as? String ?? "",
            placement: placement,
            size: SIMD2(size[0], size[1]),
            alpha: WEAnimatedValue(object["alpha"], properties: properties, default: 1),
            color: SIMD3(color[0], color[1], color[2]),
            brightness: WEJSON.float(object["brightness"], properties: properties, default: 1),
            blendMode: WEJSON.int(object["colorBlendMode"], in: 0 ... 64, default: 0),
            base: base,
            copiesBackground: copiesBackground,
            effects: effects,
        )
    }

    private static func effect(file: String, overrides: [String: Any], files: WEFileSystem) -> Effect? {
        guard let definition = files.json(file) else { return nil }
        var buffers: [String: Int] = [:]
        for fbo in (definition["fbos"] as? [[String: Any]] ?? []).prefix(WELimit.buffersPerEffect) {
            if let name = fbo["name"] as? String {
                buffers[name] = WEJSON.int(fbo["scale"], in: 1 ... 64, default: 1)
            }
        }
        let sceneOverrides = overrides["passes"] as? [[String: Any]] ?? []
        var passes: [Pass] = []
        let definitions = (definition["passes"] as? [[String: Any]] ?? []).prefix(WELimit.passesPerEffect)
        for (index, passDefinition) in definitions.enumerated() {
            guard let materialPath = passDefinition["material"] as? String,
                  var pass = pass(fromMaterial: materialPath, files: files)
            else {
                // `command` passes (copy/swap) carry no material; they are rare in 2D scenes.
                continue
            }
            pass.target = passDefinition["target"] as? String
            pass.binds = (passDefinition["bind"] as? [[String: Any]] ?? []).compactMap { bind in
                guard let name = bind["name"] as? String,
                      let slot = WEJSON.floats(bind["index"])?.first, (0 ..< Float(WELimit.textureSlots)).contains(slot)
                else { return nil }
                return (name, Int(slot))
            }
            if index < sceneOverrides.count {
                apply(sceneOverrides[index], to: &pass)
            }
            passes.append(pass)
        }
        return passes.isEmpty ? nil : Effect(passes: passes, buffers: buffers)
    }

    /// Pass 0 of a material file.
    static func pass(fromMaterial path: String, files: WEFileSystem) -> Pass? {
        guard let material = files.json(path),
              let first = (material["passes"] as? [[String: Any]])?.first,
              let shader = first["shader"] as? String
        else { return nil }
        return Pass(
            shader: shader,
            combos: combos(first["combos"]),
            textures: (first["textures"] as? [Any] ?? []).prefix(WELimit.textureSlots).map { $0 as? String },
            constants: first["constantshadervalues"] as? [String: Any] ?? [:],
            blending: first["blending"] as? String ?? "translucent",
            target: nil,
            binds: [],
        )
    }

    private static func apply(_ override: [String: Any], to pass: inout Pass) {
        pass.combos.merge(combos(override["combos"])) { _, new in new }
        if let constants = override["constantshadervalues"] as? [String: Any] {
            pass.constants.merge(constants) { _, new in new }
        }
        if let textures = override["textures"] as? [Any] {
            for (slot, value) in textures.prefix(WELimit.textureSlots).enumerated() {
                guard let name = value as? String else { continue }
                while pass.textures.count <= slot {
                    pass.textures.append(nil)
                }
                pass.textures[slot] = name
            }
        }
    }

    private static func combos(_ value: Any?) -> [String: Int] {
        var result: [String: Int] = [:]
        for (key, value) in value as? [String: Any] ?? [:] {
            result[key] = WEJSON.int(value, in: -1_000 ... 1_000, default: 0)
        }
        return result
    }

    // MARK: - Particles

    private static func particleLayer(
        _ object: [String: Any], file: String, files: WEFileSystem, properties: [String: Any],
    ) -> ParticleLayer? {
        guard let definition = files.json(file),
              let materialPath = definition["material"] as? String,
              let material = pass(fromMaterial: materialPath, files: files)
        else { return nil }
        let instance = object["instanceoverride"] as? [String: Any] ?? [:]
        func multiplier(_ key: String) -> Float {
            WEJSON.float(instance[key], properties: properties, default: 1)
        }
        let colorOverride = instance["color"].flatMap {
            WEJSON.floats($0, properties: properties)
        }.flatMap { $0.count >= 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
        return ParticleLayer(
            name: object["name"] as? String ?? "",
            placement: placement(of: object, properties: properties),
            definition: definition,
            material: material,
            countMultiplier: multiplier("count"),
            sizeMultiplier: multiplier("size"),
            alphaMultiplier: multiplier("alpha"),
            speedMultiplier: multiplier("speed"),
            lifetimeMultiplier: multiplier("lifetime"),
            rateMultiplier: multiplier("rate"),
            colorOverride: colorOverride,
        )
    }
}

/// A number that may follow a keyframed timeline:
/// `{"animation": {"c0": [{"frame": 107, "value": 0}, …], "options": {"fps": 30, "length": 360,
/// "mode": "single"}}, "value": 1}`.
///
/// A `single` timeline plays once when Wallpaper Engine starts (an intro, a notice
/// that fades away), so a looping video takes the value it settles on. `loop` and
/// `mirror` timelines repeat and are evaluated per frame. Keyframes are joined
/// linearly; Wallpaper Engine's Bézier handles are not followed.
nonisolated struct WEAnimatedValue {
    private let constant: Float
    private let keyframes: [(time: Float, value: Float)]
    private let length: Float
    private let mirror: Bool

    init(_ raw: Any?, properties: [String: Any], default fallback: Float) {
        guard let dict = raw as? [String: Any], let animation = dict["animation"] as? [String: Any],
              let channel = animation["c0"] as? [[String: Any]], !channel.isEmpty
        else {
            constant = WEJSON.float(raw, properties: properties, default: fallback)
            keyframes = []
            length = 0
            mirror = false
            return
        }
        let options = animation["options"] as? [String: Any] ?? [:]
        let fps = max(1, WEJSON.float(options["fps"], default: 30))
        let frames = channel.compactMap { key -> (time: Float, value: Float)? in
            guard let frame = WEJSON.floats(key["frame"])?.first, let value = WEJSON.floats(key["value"])?.first
            else { return nil }
            return (frame / fps, value)
        }.sorted { $0.time < $1.time }
        let mode = options["mode"] as? String ?? "loop"
        guard let last = frames.last, mode != "single" else {
            constant = frames.last?.value ?? WEJSON.float(dict["value"], default: fallback)
            keyframes = []
            length = 0
            mirror = false
            return
        }
        constant = frames[0].value
        keyframes = frames
        length = max(WEJSON.float(options["length"], default: 0) / fps, last.time)
        mirror = mode == "mirror"
    }

    /// Whether the value changes over time.
    var isAnimated: Bool {
        !keyframes.isEmpty && length > 0
    }

    /// The timeline's period in seconds, 0 when constant.
    var period: Float {
        isAnimated ? (mirror ? length * 2 : length) : 0
    }

    func value(at time: Double) -> Float {
        guard isAnimated, let last = keyframes.last else { return constant }
        var t = Float(time).truncatingRemainder(dividingBy: period)
        if mirror, t > length {
            t = 2 * length - t
        }
        guard let next = keyframes.firstIndex(where: { $0.time >= t }) else { return last.value }
        guard next > 0 else { return keyframes[0].value }
        let a = keyframes[next - 1]
        let b = keyframes[next]
        let span = max(b.time - a.time, 0.0001)
        return a.value + (b.value - a.value) * (t - a.time) / span
    }
}
