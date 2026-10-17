import Foundation

/// Bounds on what a wallpaper's files may ask for. They are downloads from
/// strangers, and their numbers decide buffer sizes, loop counts and allocations.
nonisolated enum WELimit {
    /// Widest texture or render target, in pixels.
    static let dimension = 16_384
    /// Texture slots a pass may fill; Wallpaper Engine's shaders use up to eight.
    static let textureSlots = 16
    /// Effects on one layer, passes in one effect, and buffers in one effect.
    static let effectsPerLayer = 32
    static let passesPerEffect = 16
    static let buffersPerEffect = 8
    /// Live particles in one system.
    static let particles = 20_000
    /// Seconds a particle system pre-simulates before its first frame.
    static let particleStart = 60.0
    /// Shader source after includes, in bytes.
    static let shaderBytes = 512 * 1_024
    static let includeDepth = 32
}

nonisolated extension Int {
    /// `value` rounded and held inside `range`: an infinity lands on the bound it
    /// points at, NaN on the lower one. `Int(Float)` traps on both.
    init(clamping value: some BinaryFloatingPoint, to range: ClosedRange<Int>) {
        guard !value.isNaN else {
            self = range.lowerBound
            return
        }
        let rounded = Double(value.rounded())
        if rounded <= Double(range.lowerBound) {
            self = range.lowerBound
        } else if rounded >= Double(range.upperBound) {
            self = range.upperBound
        } else {
            self = Int(rounded)
        }
    }
}

/// Reads a Wallpaper Engine `scene.pkg`: a `PKGV00NN` header, a table of
/// `(path, offset, size)` entries, then the file bytes. Offsets count from the end of
/// the table.
nonisolated struct WEPackage {
    private let data: Data
    private let entries: [String: Range<Int>]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var reader = ByteReader(data: data)
        let magic = try reader.lengthPrefixedString()
        guard magic.hasPrefix("PKGV") else { throw WEError.malformed("\(url.lastPathComponent) is not a package") }
        let count = try reader.uint32()
        var table: [(String, Int, Int)] = []
        for _ in 0 ..< count {
            let path = try reader.lengthPrefixedString()
            let offset = try Int(reader.uint32())
            let size = try Int(reader.uint32())
            table.append((path, offset, size))
        }
        let base = reader.offset
        var entries: [String: Range<Int>] = [:]
        for (path, offset, size) in table {
            let start = base + offset
            guard start + size <= data.count else { continue }
            entries[WEFileSystem.normalize(path)] = start ..< start + size
        }
        self.data = data
        self.entries = entries
    }

    func read(_ path: String) -> Data? {
        entries[path].map { data.subdata(in: $0) }
    }
}

/// Layered lookup the way Wallpaper Engine resolves a path: the wallpaper's package,
/// then its folder, then the shared `assets/` folder of the Wallpaper Engine install.
nonisolated struct WEFileSystem {
    let package: WEPackage?
    let folder: URL
    let assets: URL?

    init(folder: URL, assets: URL?) throws {
        let packageURL = folder.appendingPathComponent("scene.pkg")
        package = FileManager.default.fileExists(atPath: packageURL.path) ? try WEPackage(url: packageURL) : nil
        self.folder = folder
        self.assets = assets
    }

    /// Forward slashes, no leading `./` or `/`: the form package tables use.
    static func normalize(_ path: String) -> String {
        var path = path.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") || path.hasPrefix("/") {
            path.removeFirst(path.hasPrefix("./") ? 2 : 1)
        }
        return path
    }

    func read(_ path: String) -> Data? {
        let path = Self.normalize(path)
        if let data = package?.read(path) {
            return data
        }
        for base in [folder, assets].compactMap(\.self) {
            let url = base.appendingPathComponent(path)
            // Paths come from wallpaper files: never follow one out of its root.
            guard PathSafety.contained(url, in: base) else { continue }
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }

    func json(_ path: String) -> [String: Any]? {
        guard let data = read(path) else { return nil }
        return WEJSON.object(from: data)
    }

    /// A text file with `\r\n` turned into `\n`: Swift treats `\r\n` as one
    /// character, so CRLF files would never split into lines.
    func text(_ path: String) -> String? {
        read(path).flatMap { String(bytes: $0, encoding: .utf8) }?.replacingOccurrences(of: "\r\n", with: "\n")
    }
}

nonisolated enum WEError: LocalizedError {
    case malformed(String)
    case missing(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case let .malformed(what): "The wallpaper's files are damaged: \(what)."
        case let .missing(what): "The wallpaper needs a file that isn't there: \(what)."
        case let .unsupported(what): "This wallpaper uses something Phosphene can't render yet: \(what)."
        }
    }
}

/// Little-endian reader over the binary formats (`.pkg`, `.tex`).
nonisolated struct ByteReader {
    let data: Data
    /// Bytes read so far; also the next read's position from the data's start.
    private(set) var offset = 0

    var remaining: Int {
        data.count - offset
    }

    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw WEError.malformed("unexpected end of data") }
        let start = data.startIndex + offset
        let value = UInt32(data[start]) | UInt32(data[start + 1]) << 8
            | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
        offset += 4
        return value
    }

    mutating func int32() throws -> Int32 {
        try Int32(bitPattern: uint32())
    }

    mutating func float() throws -> Float {
        try Float(bitPattern: uint32())
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WEError.malformed("unexpected end of data") }
        let start = data.startIndex + offset
        offset += count
        return data.subdata(in: start ..< start + count)
    }

    mutating func lengthPrefixedString() throws -> String {
        let length = try Int(uint32())
        return try String(bytes: bytes(length), encoding: .utf8) ?? ""
    }

    /// A NUL-terminated magic like `TEXV0005`; the longest real one is nine bytes.
    mutating func magic() throws -> String {
        var scalars: [UInt8] = []
        while remaining > 0 {
            let byte = data[data.startIndex + offset]
            offset += 1
            if byte == 0 {
                return String(bytes: scalars, encoding: .utf8) ?? ""
            }
            guard scalars.count < 16 else { throw WEError.malformed("magic") }
            scalars.append(byte)
        }
        return String(bytes: scalars, encoding: .utf8) ?? ""
    }
}

/// Wallpaper Engine's JSON is loosely typed: vectors are `"1 0.5 0"` strings, any
/// value may be a `{"user": …, "value": …}` binding to a wallpaper property, and
/// booleans and numbers interchange. These helpers read it the way the engine does,
/// and keep infinities and NaN out: `"inf"` parses as a number, and JSON `1e300`
/// overflows `Float`.
nonisolated enum WEJSON {
    static func object(from data: Data) -> [String: Any]? {
        // Some files carry a UTF-8 BOM or trailing NULs.
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data = data.dropFirst(3)
        }
        while data.last == 0 {
            data = data.dropLast()
        }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    /// The value a possibly user-bound field resolves to with `properties`.
    static func resolve(_ value: Any?, properties: [String: Any]) -> Any? {
        guard let dict = value as? [String: Any] else { return value }
        if let user = dict["user"] {
            let name = (user as? String) ?? ((user as? [String: Any])?["name"] as? String)
            if let name, let bound = properties[name] {
                if let condition = (user as? [String: Any])?["condition"] {
                    return "\(bound)" == "\(condition)"
                }
                return bound
            }
        }
        return dict["value"] ?? (dict["user"] == nil ? value : nil)
    }

    static func floats(_ value: Any?, properties: [String: Any] = [:]) -> [Float]? {
        let parts: [Float] = switch resolve(value, properties: properties) {
        case let number as NSNumber: [number.floatValue]
        case let string as String: string.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Float($0) }
        case let array as [Any]: array.compactMap { ($0 as? NSNumber)?.floatValue }
        default: []
        }
        let finite = parts.filter(\.isFinite)
        return finite.isEmpty ? nil : finite
    }

    static func float(_ value: Any?, properties: [String: Any] = [:], default fallback: Float) -> Float {
        floats(value, properties: properties)?.first ?? fallback
    }

    /// A whole number held inside `range`.
    static func int(_ value: Any?, in range: ClosedRange<Int>, default fallback: Int) -> Int {
        guard let first = floats(value)?.first else { return fallback }
        return Int(clamping: first, to: range)
    }

    static func vector(
        _ value: Any?, count: Int, properties: [String: Any] = [:], default fallback: [Float],
    ) -> [Float] {
        guard var values = floats(value, properties: properties), !values.isEmpty else { return fallback }
        if values.count == 1, count > 1 {
            values = Array(repeating: values[0], count: count)
        }
        while values.count < count {
            values.append(fallback.indices.contains(values.count) ? fallback[values.count] : 0)
        }
        return Array(values.prefix(count))
    }

    static func bool(_ value: Any?, properties: [String: Any] = [:], default fallback: Bool) -> Bool {
        switch resolve(value, properties: properties) {
        case let number as NSNumber: number.boolValue
        case let string as String: ["1", "true", "yes"].contains(string.lowercased())
        default: fallback
        }
    }
}
