import Foundation
import Testing

/// The parts of the Wallpaper Engine importer that run without a GPU: reading the
/// loosely typed JSON, keyframed values, finding Workshop folders, and turning
/// Wallpaper Engine's shader dialect into GLSL 4.10.
struct WallpaperEngineTests {
    // MARK: - JSON

    @Test
    func `vectors read from strings numbers and arrays`() {
        #expect(WEJSON.floats("1 0.5 0") == [1, 0.5, 0])
        #expect(WEJSON.floats(NSNumber(value: 2.5)) == [2.5])
        #expect(WEJSON.floats([1, 2] as [Any]) == [1, 2])
        #expect(WEJSON.vector("0.3", count: 3, default: [0, 0, 0]) == [0.3, 0.3, 0.3])
    }

    @Test
    func `user bindings resolve to the project property`() {
        let properties: [String: Any] = ["color": "1 0 0", "shake": "1"]
        let bound: [String: Any] = ["user": "color", "value": "0 0 1"]
        #expect(WEJSON.floats(bound, properties: properties) == [1, 0, 0])
        let conditional: [String: Any] = ["user": ["name": "shake", "condition": "0"], "value": true]
        #expect(WEJSON.bool(conditional, properties: properties, default: true) == false)
        let unbound: [String: Any] = ["user": "missing", "value": "0 0 1"]
        #expect(WEJSON.floats(unbound, properties: properties) == [0, 0, 1])
    }

    @Test
    func `numbers that are not finite are dropped`() {
        #expect(WEJSON.floats("nan 1 inf") == [1])
        #expect(WEJSON.floats("nan") == nil)
        #expect(WEJSON.floats(NSNumber(value: 1e300)) == nil)
        #expect(WEJSON.int(NSNumber(value: 1e300), in: 0 ... 10, default: 3) == 3)
        #expect(WEJSON.int(NSNumber(value: 1e30), in: 0 ... 10, default: 3) == 10)
        #expect(WEJSON.int("nan", in: 0 ... 10, default: 3) == 3)
        #expect(Int(clamping: Float.nan, to: 1 ... 8) == 1)
        #expect(Int(clamping: Float.infinity, to: 1 ... 8) == 8)
        #expect(Int(clamping: -3.0 as Float, to: 1 ... 8) == 1)
        #expect(Int(clamping: 3.6 as Float, to: 1 ... 8) == 4)
    }

    // MARK: - Animated values

    @Test
    func `single timeline settles on its last keyframe`() {
        let notice: [String: Any] = [
            "animation": [
                "c0": [["frame": 107, "value": 0], ["frame": 131, "value": 0.9], ["frame": 316, "value": 0]],
                "options": ["fps": 30, "length": 360, "mode": "single"],
            ],
            "value": 1,
        ]
        let value = WEAnimatedValue(notice, properties: [:], default: 1)
        #expect(!value.isAnimated)
        #expect(value.value(at: 5) == 0)
    }

    @Test
    func `loop timeline interpolates and repeats`() {
        let pulse: [String: Any] = [
            "animation": [
                "c0": [["frame": 0, "value": 0], ["frame": 30, "value": 1]],
                "options": ["fps": 30, "length": 60, "mode": "loop"],
            ],
        ]
        let value = WEAnimatedValue(pulse, properties: [:], default: 1)
        #expect(value.period == 2)
        #expect(abs(value.value(at: 0.5) - 0.5) < 0.001)
        #expect(abs(value.value(at: 2.5) - 0.5) < 0.001)
    }

    // MARK: - Shaders

    private func shaderFolder(_ files: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("we-test-\(UUID().uuidString)")
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return folder
    }

    @Test
    func `translates the dialect and hoists early uniforms`() throws {
        let folder = try shaderFolder([
            "shaders/blur.h": "vec4 blur(vec2 uv) { return texSample2D(g_Texture0, uv); }\r\n",
            "shaders/test.vert": """
            attribute vec3 a_Position;\r
            varying vec2 v_TexCoord;\r
            void main() { gl_Position = vec4(a_Position, 1.0); }\r
            """,
            "shaders/test.frag": """
            // [COMBO] {"material":"m","combo":"MASK","default":0}\r
            #include "blur.h"\r
            uniform sampler2D g_Texture0; // {"hidden":true}\r
            uniform float g_Speed; // {"material":"speed","default":5}\r
            varying vec2 v_TexCoord;\r
            #ifdef SKINNING_ALPHA\r
            #endif\r
            void main() {\r
            #if MASK || SKINNING_ALPHA || UNSET\r
            #endif\r
                vec4 sample = blur(v_TexCoord);\r
                for (int i = -g_Speed; i < 2; i++) {}\r
                gl_FragColor = sample;\r
            }\r
            """,
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try WEShaderSource(name: "test", files: WEFileSystem(folder: folder, assets: nil))
        #expect(source.comboDefaults == ["MASK": 0])
        #expect(source.annotations["g_Speed"]?.materialKey == "speed")

        let code = source.glsl(combos: ["MASK": 1])
        #expect(code.vertex.contains("in vec3 a_Position"))
        #expect(code.vertex.contains("out vec2 v_TexCoord"))
        let fragment = code.fragment
        #expect(fragment.contains("#define MASK 1"))
        // Unset in `#if`: defined as 0. Tested by `#ifdef` too: left undefined, read as 0 in `#if`.
        #expect(fragment.contains("#define UNSET 0"))
        #expect(!fragment.contains("#define SKINNING_ALPHA"))
        #expect(fragment.contains("#if MASK || 0 || UNSET"))
        #expect(fragment.contains("vec4 sample_ = blur(v_TexCoord)"))
        #expect(fragment.contains("for (int i = int(-g_Speed);"))
        #expect(fragment.contains("out_FragColor = sample_"))
        // The header reads g_Texture0 before the shader declares it.
        let declaration = try #require(fragment.range(of: "uniform sampler2D g_Texture0"))
        let use = try #require(fragment.range(of: "texSample2D(g_Texture0"))
        #expect(declaration.lowerBound < use.lowerBound)
    }

    @Test
    func `refuses includes nested past the limit`() throws {
        var files = ["shaders/deep.vert": "void main() {}", "shaders/deep.frag": "#include \"h0.h\"\nvoid main() {}"]
        for level in 0 ... WELimit.includeDepth + 1 {
            files["shaders/h\(level).h"] = "#include \"h\(level + 1).h\"\n"
        }
        let folder = try shaderFolder(files)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: WEError.self) {
            try WEShaderSource(name: "deep", files: WEFileSystem(folder: folder, assets: nil))
        }
    }

    // MARK: - Scenes

    @Test
    func `rejects A scene whose camera has no size`() throws {
        let folder = try shaderFolder([
            "scene.json": #"{"general":{"orthogonalprojection":{"width":0,"height":1080}},"objects":[]}"#,
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: WEError.self) {
            try WEScene(files: WEFileSystem(folder: folder, assets: nil), sceneFile: "scene.json", properties: [:])
        }
    }

    @Test
    func `drops effect binds outside the texture slots`() throws {
        let folder = try shaderFolder([
            "scene.json": """
            {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
             "objects":[{"image":"models/a.json","effects":[{"file":"effects/e.json"}],"colorBlendMode":1e300}]}
            """,
            "models/a.json": #"{"material":"materials/a.json"}"#,
            "materials/a.json": #"{"passes":[{"shader":"s","textures":["t"]}]}"#,
            "effects/e.json": """
            {"passes":[{"material":"materials/a.json","bind":[{"name":"previous","index":-1},
             {"name":"previous","index":99},{"name":"previous","index":2}]}]}
            """,
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = try WEScene(files: WEFileSystem(folder: folder, assets: nil), sceneFile: "scene.json", properties: [:])
        guard case let .image(layer) = scene.layers.first else {
            Issue.record("expected an image layer")
            return
        }
        #expect(layer.effects.first?.passes.first?.binds.map(\.slot) == [2])
        #expect(layer.blendMode == 0)
    }

    // MARK: - Particles

    @Test
    func `particle numbers outside their range do not stop the simulation`() {
        let layer = WEScene.ParticleLayer(
            name: "", placement: .init(origin: .zero, scale: .one, angle: 0),
            definition: [
                "maxcount": 1e30, "starttime": 1e300, "sequencemultiplier": -1,
                "emitter": [["name": "sphererandom", "rate": 1e9, "distancemin": "nan", "distancemax": -5]],
                "initializer": [["name": "positionoffsetrandom", "distance": -5], ["name": "lifetimerandom", "min": "inf", "max": 2]],
                "operator": [["name": "oscillateposition", "frequencymin": 5, "frequencymax": 1]],
            ],
            material: WEScene.Pass(shader: "s", combos: [:], textures: [], constants: [:], blending: "additive", target: nil, binds: []),
            countMultiplier: 1e30, sizeMultiplier: 1, alphaMultiplier: 1, speedMultiplier: 1,
            lifetimeMultiplier: 1, rateMultiplier: 1, colorOverride: nil,
        )
        let system = WEParticleSystem(layer: layer, seed: 1)
        system.reset(to: 0)
        system.step(to: 1, frame: 1 / 30)
        #expect(!system.particles.isEmpty)
        #expect(system.particles.count <= WELimit.particles)
        #expect(system.particles.filter { !$0.position.x.isFinite }.isEmpty)
    }

    // MARK: - Textures

    @Test
    func `refuses A compressed mip claiming more than the budget`() {
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        func int(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        for value in [0, 0, 2, 2, 2, 2, 0] as [Int32] {
            int(value)
        }
        data.append(contentsOf: Data("TEXB0003\0".utf8))
        for value in [1, -1, 1, 2, 2, 1, Int32.max, 4] as [Int32] {
            int(value)
        }
        data.append(Data(repeating: 0, count: 4))
        #expect(throws: WEError.self) { try WETexture(data: data) }
    }

    /// A `.tex` with one RGBA8888 mip of `width × height` carrying `pixelBytes` bytes.
    private func texture(width: Int32, height: Int32, pixelBytes: Int) -> Data {
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        func int(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        for value in [0, 0, width, height, width, height, 0] as [Int32] {
            int(value)
        }
        data.append(contentsOf: Data("TEXB0003\0".utf8))
        for value in [1, -1, 1, width, height, 0, 0, Int32(pixelBytes)] as [Int32] {
            int(value)
        }
        data.append(Data(repeating: 0x7F, count: pixelBytes))
        return data
    }

    @Test
    func `accepts A texture whose pixels fill its size`() throws {
        let decoded = try WETexture(data: texture(width: 2, height: 2, pixelBytes: 16))
        guard case let .raw(_, mips) = decoded.pixels else {
            Issue.record("expected raw pixels")
            return
        }
        #expect(mips.first?.data.count == 16)
    }

    @Test
    func `rejects headers that claim more than the data`() {
        #expect(throws: WEError.self) { try WETexture(data: texture(width: 4_096, height: 4_096, pixelBytes: 16)) }
        #expect(throws: WEError.self) { try WETexture(data: texture(width: 0, height: 2, pixelBytes: 16)) }
        #expect(throws: WEError.self) { try WETexture(data: texture(width: 100_000, height: 2, pixelBytes: 16)) }
    }

    @Test
    func `rejects A short mip even when its bytes look like an MP 4`() {
        // Mip 0 is a full 2×2 RGBA image; mip 1 claims 2×2 but carries 12 bytes that open
        // with an MP4 signature. The texture is raw (decided by mip 0), so mip 1 is short.
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        func int(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        for value in [0, 0, 2, 2, 2, 2, 0] as [Int32] {
            int(value)
        }
        data.append(contentsOf: Data("TEXB0003\0".utf8))
        for value in [1, -1, 2, 2, 2, 0, 0, 16] as [Int32] {
            int(value)
        }
        data.append(Data(repeating: 0x7F, count: 16))
        for value in [2, 2, 0, 0, 12] as [Int32] {
            int(value)
        }
        data.append(contentsOf: [0, 0, 0, 0x20] + Array("ftypisom".utf8))
        #expect(throws: WEError.self) { try WETexture(data: data) }
    }

    // MARK: - Folders

    @Test
    func `manual folder finds workshop content and assets`() throws {
        let steam = try shaderFolder([
            "steamapps/workshop/content/431960/123/project.json": "{}",
            "steamapps/common/wallpaper_engine/assets/shaders/common.h": "",
        ])
        defer { try? FileManager.default.removeItem(at: steam) }
        let fromRoot = WorkshopDiscovery.manualSource(steam)
        #expect(fromRoot.contentFolder.lastPathComponent == "431960")
        #expect(fromRoot.assets?.lastPathComponent == "assets")
        let fromContent = WorkshopDiscovery.manualSource(fromRoot.contentFolder)
        #expect(fromContent.assets?.lastPathComponent == "assets")
    }

    @Test
    func `paths in A wallpaper stay inside its folder`() throws {
        let root = try shaderFolder([
            "123/project.json": #"{"title":"x","file":"../1234/secret.mp4","preview":"../1234/secret.png"}"#,
            "123/materials/ok.json": "{}",
            "1234/secret.mp4": "", "1234/secret.png": "", "1234/materials/ok.json": "{}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("123")
        let files = try WEFileSystem(folder: folder, assets: nil)
        #expect(files.read("../1234/materials/ok.json") == nil)
        #expect(files.read("materials/ok.json") != nil)
        let project = WEProject(folder: folder)
        #expect(project.mainFile == nil)
        #expect(project.preview == nil)
    }

    @Test
    func `only Steam ids open A Workshop page`() {
        func item(_ id: String) -> WorkshopItem {
            WorkshopItem(
                id: id, folder: URL(fileURLWithPath: "/tmp/\(id)"), title: "", kind: .scene, file: "scene.json",
                mainFile: nil, preview: nil, contentRating: nil, modified: .now, sizeOnDisk: 0, sourceID: "", assets: nil,
            )
        }
        #expect(item("2940184031").workshopPageURL?.absoluteString == "steam://url/CommunityFilePage/2940184031")
        #expect(item("My Wallpaper").workshopPageURL == nil)
        #expect(item("My Wallpaper/..").fileStem == "MyWallpaper")
        #expect(item("日本語").fileStem == "wallpaper")
    }

    @Test
    func `bake settings read back land inside the encoder's limits`() {
        let settings = WEBakeSettings(width: 0, height: 100_000, fps: 0, codec: .h264, loopLength: .infinity).normalized
        #expect(settings.width == 16)
        #expect(settings.height == 8_192)
        #expect(settings.fps == 1)
        #expect(settings.loopLength == nil)
    }
}
