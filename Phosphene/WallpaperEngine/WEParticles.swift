import Foundation
import simd

/// A CPU simulation of one Wallpaper Engine particle system: emitters spawn,
/// initializers set each particle's starting values, operators move and fade it.
/// Covers the 2D building blocks (sphere/box emitters, the random initializers,
/// movement, fades, size and color change, rotation, oscillation, turbulence,
/// vortex and control-point attraction); unknown entries are skipped.
final nonisolated class WEParticleSystem {
    struct Particle {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var age: Float
        var lifetime: Float
        var size: Float
        var rotation: Float
        var angularVelocity: Float
        var color: SIMD3<Float>
        var alpha: Float
        var frame: Int
        var phase: Float
        var oscillation: SIMD2<Float>
        var oscillationFrequency: Float
        // Values the operators scale each step, kept from spawn.
        var baseSize: Float
        var baseAlpha: Float
        var baseColor: SIMD3<Float>
    }

    private(set) var particles: [Particle] = []
    private let layer: WEScene.ParticleLayer
    private let emitters: [[String: Any]]
    private let initializers: [[String: Any]]
    private let operators: [[String: Any]]
    private let maxCount: Int
    private let seed: UInt64
    private var random: SplitMix
    private var time: Double = 0
    private var spawnDebt: [Float]
    /// Seconds the system runs before its first frame, so it starts populated.
    let startTime: Double
    let animationMode: String
    let sequenceMultiplier: Float

    init(layer: WEScene.ParticleLayer, seed: UInt64) {
        self.layer = layer
        let definition = layer.definition
        emitters = definition["emitter"] as? [[String: Any]] ?? []
        initializers = definition["initializer"] as? [[String: Any]] ?? []
        operators = definition["operator"] as? [[String: Any]] ?? []
        let count = WEJSON.int(definition["maxcount"], in: 1 ... WELimit.particles, default: 100)
        maxCount = Int(clamping: Float(count) * layer.countMultiplier, to: 1 ... WELimit.particles)
        self.seed = seed
        random = SplitMix(seed: seed)
        spawnDebt = Array(repeating: 0, count: emitters.count)
        startTime = min(WELimit.particleStart, max(0, Double(WEJSON.float(definition["starttime"], default: 0))))
        animationMode = definition["animationmode"] as? String ?? "sequence"
        sequenceMultiplier = WEJSON.float(definition["sequencemultiplier"], default: 1)
    }

    /// Clear and restart the clock at `time` (the system then pre-simulates its own
    /// `starttime` on the first step).
    func reset(to time: Double) {
        particles.removeAll()
        random = SplitMix(seed: seed)
        spawnDebt = Array(repeating: 0, count: emitters.count)
        self.time = time - startTime
        isPrimed = true
    }

    /// Whether ``reset(to:)`` has set the clock.
    private(set) var isPrimed = false

    /// Advance in `frame`-sized steps until the clock reaches `target`.
    func step(to target: Double, frame: Double) {
        let step = max(frame, 1.0 / 120)
        while time + step * 0.5 < target {
            advance(Float(step))
            time += step
        }
    }

    // MARK: - Simulation

    private func advance(_ delta: Float) {
        let delta = delta * layer.speedMultiplier
        for (index, emitter) in emitters.enumerated() {
            let rate = WEJSON.float(emitter["rate"], default: 5) * layer.rateMultiplier * layer.countMultiplier
            spawnDebt[index] += rate * delta
            while spawnDebt[index] >= 1 {
                spawnDebt[index] -= 1
                guard particles.count < maxCount else {
                    spawnDebt[index] = 0
                    break
                }
                particles.append(spawn(from: emitter))
            }
        }
        for index in particles.indices {
            particles[index].age += delta
        }
        particles.removeAll { $0.age >= $0.lifetime }
        // Newest particle first: operators draw random values, and a render must
        // come out the same each time it is made.
        for index in particles.indices.reversed() {
            apply(operators, to: &particles[index], delta: delta)
        }
    }

    // swiftlint:disable:next function_body_length
    private func spawn(from emitter: [String: Any]) -> Particle {
        let origin = WEJSON.vector(emitter["origin"], count: 3, default: [0, 0, 0])
        var position = SIMD2(origin[0], origin[1])
        let name = emitter["name"] as? String ?? "sphererandom"
        let directions = WEJSON.vector(emitter["directions"], count: 3, default: [1, 1, 0])
        if name == "boxrandom" {
            let minimum = WEJSON.vector(emitter["distancemin"], count: 3, default: [0, 0, 0])
            let maximum = WEJSON.vector(emitter["distancemax"], count: 3, default: [100, 100, 0])
            for axis in 0 ..< 2 {
                let magnitude = random.float(between: minimum[axis], and: maximum[axis])
                position[axis] += (random.bool() ? magnitude : -magnitude) * directions[axis]
            }
        } else {
            let minimum = WEJSON.float(emitter["distancemin"], default: 0)
            let maximum = WEJSON.float(emitter["distancemax"], default: 100)
            let angle = random.float(between: 0, and: 2 * .pi)
            let distance = random.float(between: minimum, and: maximum)
            position += SIMD2(cos(angle) * directions[0], sin(angle) * directions[1]) * distance
        }

        var particle = Particle(
            position: position, velocity: .zero, age: 0, lifetime: 1, size: 20, rotation: 0, angularVelocity: 0,
            color: SIMD3(1, 1, 1), alpha: 1, frame: 0, phase: random.float(between: 0, and: 2 * .pi),
            oscillation: .zero, oscillationFrequency: 0, baseSize: 20, baseAlpha: 1, baseColor: SIMD3(1, 1, 1),
        )
        for initializer in initializers {
            switch initializer["name"] as? String {
            case "lifetimerandom":
                particle.lifetime = randomScalar(initializer, default: (1, 1))
            case "sizerandom":
                let exponent = WEJSON.float(initializer["exponent"], default: 1)
                let lower = WEJSON.float(initializer["min"], default: 20)
                let upper = WEJSON.float(initializer["max"], default: 20)
                particle.size = lower + (upper - lower) * pow(random.unit(), exponent)
            case "velocityrandom":
                let value = randomVector(initializer, default: ([-32, -32, 0], [32, 32, 0]))
                particle.velocity += SIMD2(value[0], value[1])
            case "turbulentvelocityrandom":
                let speed = random.float(
                    between: WEJSON.float(initializer["speedmin"], default: 0),
                    and: WEJSON.float(initializer["speedmax"], default: 100),
                )
                let angle = random.float(between: 0, and: 2 * .pi)
                particle.velocity += SIMD2(cos(angle), sin(angle)) * speed
            case "colorrandom":
                let value = randomVector(initializer, default: ([255, 255, 255], [255, 255, 255]))
                particle.color = SIMD3(value[0], value[1], value[2]) / 255
            case "alpharandom":
                particle.alpha = randomScalar(initializer, default: (1, 1))
            case "rotationrandom":
                let value = randomVector(initializer, default: ([0, 0, 0], [0, 0, 2 * .pi]))
                particle.rotation = value[2]
            case "angularvelocityrandom":
                let value = randomVector(initializer, default: ([0, 0, -5], [0, 0, 5]))
                particle.angularVelocity = value[2]
            case "positionoffsetrandom":
                let distance = WEJSON.float(initializer["distance"], default: 10)
                let angle = random.float(between: 0, and: 2 * .pi)
                particle.position += SIMD2(cos(angle), sin(angle)) * random.float(between: 0, and: distance)
            default:
                continue
            }
        }
        particle.lifetime *= layer.lifetimeMultiplier
        particle.size *= layer.sizeMultiplier
        particle.alpha *= layer.alphaMultiplier
        if let colorOverride = layer.colorOverride {
            particle.color = colorOverride
        }
        particle.baseSize = particle.size
        particle.baseAlpha = particle.alpha
        particle.baseColor = particle.color
        particle.frame = Int(random.next() % 1_024)
        return particle
    }

    // swiftlint:disable:next function_body_length
    private func apply(_ operators: [[String: Any]], to particle: inout Particle, delta: Float) {
        let life = min(1, particle.age / max(particle.lifetime, 0.0001))
        particle.size = particle.baseSize
        particle.alpha = particle.baseAlpha
        particle.color = particle.baseColor
        var offset = SIMD2<Float>.zero
        for item in operators {
            switch item["name"] as? String {
            case "movement":
                let gravity = WEJSON.vector(item["gravity"], count: 3, default: [0, 0, 0])
                let drag = WEJSON.float(item["drag"], default: 0)
                particle.velocity += SIMD2(gravity[0], gravity[1]) * delta
                particle.velocity *= max(0, 1 - drag * delta)
                particle.position += particle.velocity * delta
            case "angularmovement":
                let force = WEJSON.vector(item["force"], count: 3, default: [0, 0, 0])
                let drag = WEJSON.float(item["drag"], default: 0)
                particle.angularVelocity += force[2] * delta
                particle.angularVelocity *= max(0, 1 - drag * delta)
                particle.rotation += particle.angularVelocity * delta
            case "alphafade":
                let fadeIn = WEJSON.float(item["fadeintime"], default: 0.5)
                let fadeOut = WEJSON.float(item["fadeouttime"], default: 0.5)
                if life < fadeIn {
                    particle.alpha *= life / max(fadeIn, 0.0001)
                }
                if life > fadeOut {
                    particle.alpha *= max(0, (1 - life) / max(1 - fadeOut, 0.0001))
                }
            case "sizechange":
                particle.size *= ramp(item, life: life, default: (1, 0))
            case "alphachange":
                particle.alpha *= ramp(item, life: life, default: (1, 0))
            case "colorchange":
                let start = WEJSON.vector(item["startvalue"], count: 3, default: [1, 1, 1])
                let end = WEJSON.vector(item["endvalue"], count: 3, default: [1, 1, 1])
                let t = rampProgress(item, life: life)
                particle.color *= SIMD3(start[0], start[1], start[2]) * (1 - t) + SIMD3(end[0], end[1], end[2]) * t
            case "oscillateposition":
                if particle.oscillationFrequency == 0 {
                    particle.oscillationFrequency = random.float(
                        between: WEJSON.float(item["frequencymin"], default: 0),
                        and: WEJSON.float(item["frequencymax"], default: 5),
                    )
                    let scaleMin = WEJSON.float(item["scalemin"], default: 0)
                    let scaleMax = WEJSON.float(item["scalemax"], default: 10)
                    particle.oscillation = SIMD2(
                        random.float(between: scaleMin, and: scaleMax), random.float(between: scaleMin, and: scaleMax),
                    )
                }
                let mask = WEJSON.vector(item["mask"], count: 3, default: [1, 1, 0])
                let wave = sin(particle.age * particle.oscillationFrequency + particle.phase)
                offset += SIMD2(particle.oscillation.x * mask[0], particle.oscillation.y * mask[1]) * wave
            case "turbulence":
                let scale = WEJSON.float(item["scale"], default: 0.01)
                let speed = WEJSON.float(item["speedmax"], default: 250)
                let timeScale = WEJSON.float(item["timescale"], default: 1)
                let mask = WEJSON.vector(item["mask"], count: 3, default: [1, 1, 0])
                let t = Float(time) * timeScale
                let angle = sin(particle.position.x * scale + t) * cos(particle.position.y * scale - t * 0.7)
                    * 2 * .pi
                particle.velocity += SIMD2(cos(angle) * mask[0], sin(angle) * mask[1]) * speed * delta * 0.1
            case "vortex":
                let speed = WEJSON.float(item["speedinner"], default: 50)
                let relative = particle.position
                particle.velocity += SIMD2(-relative.y, relative.x) / max(simd_length(relative), 1) * speed * delta
            case "controlpointattract":
                let scale = WEJSON.float(item["scale"], default: 1)
                let relative = -particle.position
                particle.velocity += relative / max(simd_length(relative), 1) * scale * delta
            default:
                continue
            }
        }
        particle.position += offset * delta
    }

    private func rampProgress(_ item: [String: Any], life: Float) -> Float {
        let start = WEJSON.float(item["starttime"], default: 0)
        let end = WEJSON.float(item["endtime"], default: 1)
        return min(1, max(0, (life - start) / max(end - start, 0.0001)))
    }

    private func ramp(_ item: [String: Any], life: Float, default fallback: (Float, Float)) -> Float {
        let start = WEJSON.float(item["startvalue"], default: fallback.0)
        let end = WEJSON.float(item["endvalue"], default: fallback.1)
        let t = rampProgress(item, life: life)
        return start + (end - start) * t
    }

    private func randomScalar(_ item: [String: Any], default fallback: (Float, Float)) -> Float {
        random.float(
            between: WEJSON.float(item["min"], default: fallback.0), and: WEJSON.float(item["max"], default: fallback.1),
        )
    }

    private func randomVector(_ item: [String: Any], default fallback: ([Float], [Float])) -> [Float] {
        let lower = WEJSON.vector(item["min"], count: 3, default: fallback.0)
        let upper = WEJSON.vector(item["max"], count: 3, default: fallback.1)
        return (0 ..< 3).map { random.float(between: lower[$0], and: upper[$0]) }
    }
}

/// Deterministic random numbers, so a render repeats exactly.
nonisolated struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    /// A value between two bounds given in either order; a bound that is not a
    /// number reads as 0.
    mutating func float(between a: Float, and b: Float) -> Float {
        let a = a.isFinite ? a : 0
        let b = b.isFinite ? b : 0
        return min(a, b) + abs(b - a) * unit()
    }

    mutating func bool() -> Bool {
        next() & 1 == 1
    }
}

/// Draws particle systems as instanced, rotated, tinted sprites.
final nonisolated class WEParticleRenderer {
    private let gl: GL
    private let program: GLProgram
    private let vertexArray: UInt32
    private let cornerBuffer: UInt32
    private let instanceBuffer: UInt32
    private static let instanceStride = 12

    init(gl: GL) throws {
        self.gl = gl
        program = try GLProgram(
            gl: gl, vertex: Self.vertexSource, fragment: Self.fragmentSource, attributes: ["i_Transform", "i_Color", "i_UV"],
        )
        vertexArray = gl.genVertexArray()
        gl.bindVertexArray(vertexArray)
        cornerBuffer = gl.genBuffer()
        gl.bufferData(cornerBuffer, floats: [
            -0.5, 0.5, 0, 0, 0,
            0.5, 0.5, 0, 1, 0,
            -0.5, -0.5, 0, 0, 1,
            0.5, -0.5, 0, 1, 1,
        ], usage: GLConst.staticDraw)
        gl.vertexAttribute(0, components: 3, stride: 5, offset: 0)
        gl.vertexAttribute(1, components: 2, stride: 5, offset: 3)
        instanceBuffer = gl.genBuffer()
        gl.bufferData(instanceBuffer, floats: Array(repeating: 0, count: Self.instanceStride))
        gl.vertexAttribute(2, components: 4, stride: Self.instanceStride, offset: 0, divisor: 1)
        gl.vertexAttribute(3, components: 4, stride: Self.instanceStride, offset: 4, divisor: 1)
        gl.vertexAttribute(4, components: 4, stride: Self.instanceStride, offset: 8, divisor: 1)
    }

    func release() {
        program.delete()
        gl.deleteVertexArray(vertexArray)
        gl.deleteBuffer(cornerBuffer)
        gl.deleteBuffer(instanceBuffer)
    }

    /// Refraction: each particle shows the scene behind it, displaced by a normal map.
    struct Refraction {
        let normalMap: WEGLTexture
        let background: UInt32
        let amount: Float
    }

    func draw(
        _ system: WEParticleSystem, layer: WEScene.ParticleLayer, texture: WEGLTexture, sceneSize: SIMD2<Float>,
        refraction: Refraction?, overbright: Float,
    ) {
        guard !system.particles.isEmpty else { return }
        let instances = instances(of: system, layer: layer, texture: texture)
        program.use()
        gl.blend(layer.material.blending == "additive" ? .additive : .translucent)
        gl.bindTexture(texture.name, unit: 0)
        program.set("u_Texture", int: 0)
        program.set("u_SceneSize", floats: [sceneSize.x, sceneSize.y], type: GLConst.typeVec2)
        program.set("u_Format", int: Int32(texture.formatCode))
        program.set("u_Overbright", floats: [overbright], type: GLConst.typeFloat)
        program.set("u_Refract", int: refraction == nil ? 0 : 1)
        if let refraction {
            gl.bindTexture(refraction.normalMap.name, unit: 1)
            gl.bindTexture(refraction.background, unit: 2)
            program.set("u_Normal", int: 1)
            program.set("u_Background", int: 2)
            program.set("u_NormalFormat", int: Int32(refraction.normalMap.formatCode))
            program.set("u_RefractAmount", floats: [refraction.amount], type: GLConst.typeFloat)
        }
        gl.bindVertexArray(vertexArray)
        gl.bufferData(instanceBuffer, floats: instances)
        gl.drawArraysInstanced(GLConst.triangleStrip, count: 4, instances: system.particles.count)
    }

    /// One `instanceStride`-float record per particle: position, size, rotation,
    /// color, and the sprite frame's rectangle in the texture.
    private func instances(
        of system: WEParticleSystem, layer: WEScene.ParticleLayer, texture: WEGLTexture,
    ) -> [Float] {
        let frames = texture.spriteFrames
        let placement = layer.placement
        let cosine = cos(placement.angle)
        let sine = sin(placement.angle)
        var instances: [Float] = []
        instances.reserveCapacity(system.particles.count * Self.instanceStride)
        for particle in system.particles {
            let local = particle.position * placement.scale
            let world = placement.origin + SIMD2(local.x * cosine - local.y * sine, local.x * sine + local.y * cosine)
            let uv: SIMD4<Float>
            if frames.isEmpty {
                let extent = texture.imageExtent
                uv = SIMD4(0, 0, extent.x, extent.y)
            } else {
                let count = Float(frames.count)
                let position = system.animationMode == "randomframe"
                    ? Float(particle.frame % frames.count)
                    : particle.age / max(particle.lifetime, 0.0001) * count * system.sequenceMultiplier
                let frame = frames[position.isFinite ? Int(abs(position).truncatingRemainder(dividingBy: count)) : 0]
                let res = texture.resolution
                uv = SIMD4(frame.x / res.x, frame.y / res.y, frame.width / res.x, frame.height / res.y)
            }
            instances += [
                world.x, world.y, particle.size * placement.scale.x, particle.rotation + placement.angle,
                particle.color.x, particle.color.y, particle.color.z, particle.alpha,
                uv.x, uv.y, uv.z, uv.w,
            ]
        }
        return instances
    }

    private static let vertexSource = """
    #version 410
    in vec3 a_Position;
    in vec2 a_TexCoord;
    in vec4 i_Transform;
    in vec4 i_Color;
    in vec4 i_UV;
    uniform vec2 u_SceneSize;
    out vec2 v_UV;
    out vec4 v_Color;
    out vec2 v_Screen;
    out float v_Rotation;
    void main() {
        float c = cos(i_Transform.w);
        float s = sin(i_Transform.w);
        vec2 corner = a_Position.xy * i_Transform.z;
        vec2 world = i_Transform.xy + vec2(corner.x * c - corner.y * s, corner.x * s + corner.y * c);
        gl_Position = vec4(world.x / u_SceneSize.x * 2.0 - 1.0, 1.0 - world.y / u_SceneSize.y * 2.0, 0.0, 1.0);
        v_UV = i_UV.xy + a_TexCoord * i_UV.zw;
        v_Color = i_Color;
        v_Screen = gl_Position.xy * 0.5 + 0.5;
        v_Rotation = i_Transform.w;
    }
    """

    /// Single-channel textures are coverage: R8 is alpha, RG88 is luminance and alpha.
    /// A refracting particle multiplies by the scene behind it, displaced along its
    /// normal map: RGBA maps carry x in alpha, y in green and the mask in red; RG88
    /// carries y, x; compressed maps match RGBA with x biased by 0.965.
    private static let fragmentSource = """
    #version 410
    in vec2 v_UV;
    in vec4 v_Color;
    in vec2 v_Screen;
    in float v_Rotation;
    uniform sampler2D u_Texture;
    uniform sampler2D u_Normal;
    uniform sampler2D u_Background;
    uniform int u_Format;
    uniform int u_NormalFormat;
    uniform int u_Refract;
    uniform float u_RefractAmount;
    uniform float u_Overbright;
    out vec4 o_Color;
    void main() {
        vec4 texel = texture(u_Texture, v_UV);
        if (u_Format == 9) texel = vec4(1.0, 1.0, 1.0, texel.r);
        else if (u_Format == 8) texel = texel.rrrg;
        vec4 color = texel * v_Color;
        if (u_Refract == 1) {
            vec4 n = texture(u_Normal, v_UV);
            vec2 normal;
            float mask = n.r;
            if (u_NormalFormat == 8) { normal = n.gr * 2.0 - 1.0; mask = 1.0; }
            else if (u_NormalFormat >= 3 && u_NormalFormat <= 7) normal = vec2(n.a * 2.0 - 0.965, n.g * 2.0 - 1.0);
            else normal = vec2(n.a, n.g) * 2.0 - 1.0;
            float c = cos(v_Rotation);
            float s = sin(v_Rotation);
            vec2 offset = vec2(normal.x * c - normal.y * s, normal.x * s + normal.y * c);
            offset *= u_RefractAmount * mask * v_Color.a;
            color.rgb *= texture(u_Background, v_Screen + offset).rgb;
        }
        color.rgb *= u_Overbright;
        o_Color = color;
    }
    """
}
