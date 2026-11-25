import CoreGraphics
import Foundation

/// The owner remains the Library choice when the appearance roles are swapped.
nonisolated struct AppearancePair: Codable, Equatable, Sendable {
    let owner: String
    let counterpart: String
    var swapped: Bool
    let validation: Validation
    var name: String?
    private(set) var deletionPending: Bool?
    private(set) var optimization: Optimization?
    private(set) var membershipID: UUID? = UUID()

    struct Validation: Codable, Equatable, Sendable {
        var version = 1
        let original: FileIdentity
        let alternate: FileIdentity
        let frameTicks: Int64
        let timescale: Int32
        let frameCount: Int
        let commonSyncFrames: [Int]
    }

    struct Tier: Codable, Equatable, Sendable {
        let fps: Int
        let resolution: CGSize
        let validation: Validation

        fileprivate func identity(alternate: Bool) -> FileIdentity {
            alternate ? validation.alternate : validation.original
        }

        fileprivate var isValid: Bool {
            fps > 0 && resolution.width.isFinite && resolution.width >= 1 &&
                resolution.height.isFinite && resolution.height >= 1 &&
                validation.version == 1 && validation.timescale > 0 && validation.frameTicks > 0 &&
                validation.frameCount > 0 && Int64(validation.frameCount) <= Int64.max / validation.frameTicks &&
                validation.commonSyncFrames.first == 0 &&
                validation.commonSyncFrames.allSatisfy { (0 ..< validation.frameCount).contains($0) }
        }
    }

    struct Optimization: Codable, Equatable, Sendable {
        let generation: UUID
        let tiers: [Tier]
        var toneMappedToSDR: Bool? = nil
    }

    var light: String {
        swapped ? counterpart : owner
    }
    var dark: String {
        swapped ? owner : counterpart
    }

    func contains(_ id: String) -> Bool {
        id == owner || id == counterpart
    }

    static func read(in directory: URL) throws -> [Self] {
        let url = directory.appendingPathComponent(".appearance-pairs.json")
        do {
            let pairs = try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
            let ids = pairs.flatMap { [$0.owner, $0.counterpart] }
            guard ids.allSatisfy(PathSafety.isValidEntryID), Set(ids).count == ids.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return pairs
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    /// Serialize the membership check with mutations from the host and the Settings extension.
    static func withLibraryLock<T>(in directory: URL, _ body: () throws -> T) throws -> T {
        let fd = unsafe open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return try body()
    }

    static func update(
        in directory: URL,
        afterCommit: () -> Void = {},
        onFailure: () -> Void = {},
        _ change: (inout [Self]) throws -> Void,
    ) throws {
        try withLibraryLock(in: directory) {
            var pairs = try read(in: directory)
            do {
                try change(&pairs)
                try write(pairs, in: directory)
            } catch {
                onFailure()
                throw error
            }
            afterCommit()
        }
    }

    private static func write(_ pairs: [Self], in directory: URL) throws {
        try JSONEncoder().encode(pairs).write(to: directory.appendingPathComponent(".appearance-pairs.json"), options: .atomic)
    }

    static func requireSingle(_ id: String, in directory: URL) throws {
        guard try !read(in: directory).contains(where: { $0.contains(id) }) else {
            throw PairIssue.alreadyPaired
        }
    }

    func merge(in directory: URL, onFailure: () -> Void = {}, files: () throws -> (URL, URL)) throws {
        try Self.update(in: directory, onFailure: onFailure) { pairs in
            guard PathSafety.isValidEntryID(owner), PathSafety.isValidEntryID(counterpart), owner != counterpart,
                  !pairs.contains(where: { $0.contains(owner) || $0.contains(counterpart) }) else { throw PairIssue.alreadyPaired }
            let (first, second) = try files()
            guard deletionPending != true, optimization == nil, validation.version == 1, validation.original == FileIdentity(of: first),
                  validation.alternate == FileIdentity(of: second) else { throw PairIssue.changed }
            pairs.append(self)
        }
    }

    func edit(in directory: URL, split: Bool) throws {
        try Self.update(in: directory, afterCommit: {
            if split {
                pruneGenerations(in: directory)
            }
        }) { pairs in
            guard deletionPending != true, let index = pairs.firstIndex(of: self) else { throw PairIssue.changed }
            if split {
                pairs.remove(at: index)
            } else {
                pairs[index].swapped.toggle()
            }
        }
    }

    // MARK: - Optimized pair storage

    /// Resolve a tier by its physical role (owner or counterpart), independent of swaps.
    func optimizedURL(for tier: Tier, alternate: Bool, in libraryDirectory: URL) -> URL? {
        guard deletionPending != true, let optimization, optimization.tiers.contains(tier),
              let ownerDirectory = optimizationOwner(in: libraryDirectory), tier.validation.version == 1 else { return nil }
        return Self.tierURL(tier, alternate: alternate, in: Self.generationURL(optimization.generation, under: ownerDirectory))
    }

    func deployOptimization(
        from staging: URL,
        tiers: [Tier],
        convertToSDR: Bool,
        in directory: URL,
        checkSources: (Self) throws -> Void,
    ) throws {
        try Self.withLibraryLock(in: directory) {
            var pairs = try Self.read(in: directory)
            let index = try optimizationIndex(in: pairs)
            try checkSources(pairs[index])
            let stagingName = staging.lastPathComponent
            guard let ownerDirectory = optimizationOwner(in: directory), staging.isFileURL,
                  stagingName.hasPrefix(".optimization-"),
                  UUID(uuidString: String(stagingName.dropFirst(".optimization-".count))) != nil,
                  staging.path == directory.appendingPathComponent(stagingName, isDirectory: true).path,
                  Self.isValidStaging(staging, tiers: tiers) else { throw PairIssue.changed }

            let generation = UUID()
            let destination = Self.generationURL(generation, under: ownerDirectory)
            guard unsafe renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            pairs[index].optimization = Optimization(generation: generation, tiers: tiers, toneMappedToSDR: convertToSDR ? true : nil)
            do {
                try Self.write(pairs, in: directory)
            } catch {
                if unsafe renamex_np(destination.path, staging.path, UInt32(RENAME_EXCL)) != 0 {
                    try? FileManager.default.removeItem(at: destination)
                }
                throw error
            }
            pruneGenerations(in: directory, keeping: generation)
        }
    }

    func removeOptimization(in directory: URL) throws {
        try Self.update(in: directory, afterCommit: { pruneGenerations(in: directory) }) { pairs in
            let index = try optimizationIndex(in: pairs)
            pairs[index].optimization = nil
        }
    }

    private func optimizationIndex(in pairs: [Self]) throws -> Int {
        guard let index = pairs.firstIndex(where: {
            $0.owner == owner && $0.counterpart == counterpart && $0.validation == validation && $0.membershipID == membershipID &&
                $0.deletionPending != true && $0.optimization?.generation == optimization?.generation
        }) else { throw PairIssue.changed }
        return index
    }

    private static let generationPrefix = ".paired-variants-"

    private func optimizationOwner(in directory: URL) -> URL? {
        let url = directory.appendingPathComponent(owner, isDirectory: true)
        guard PathSafety.isValidEntryID(owner), PathSafety.isItem(at: url, ofType: .typeDirectory) else { return nil }
        return url
    }

    private static func generationURL(_ generation: UUID, under ownerDirectory: URL) -> URL {
        ownerDirectory.appendingPathComponent(generationPrefix + generation.uuidString, isDirectory: true)
    }

    private static func tierURL(_ tier: Tier, alternate: Bool, in generation: URL) -> URL? {
        let identity = tier.identity(alternate: alternate)
        let side = generation.appendingPathComponent(alternate ? "alternate" : "original", isDirectory: true)
        guard PathSafety.isSafeComponent(identity.basename), PathSafety.isItem(at: generation, ofType: .typeDirectory),
              PathSafety.isItem(at: side, ofType: .typeDirectory) else { return nil }
        let url = side.appendingPathComponent(identity.basename, isDirectory: false)
        guard PathSafety.isItem(at: url, ofType: .typeRegular), FileIdentity(of: url) == identity else { return nil }
        return url
    }

    private static func isValidStaging(_ directory: URL, tiers: [Tier]) -> Bool {
        let fm = FileManager.default
        guard !tiers.isEmpty, tiers.allSatisfy(\.isValid),
              PathSafety.isItem(at: directory, ofType: .typeDirectory),
              let contents = try? fm.contentsOfDirectory(atPath: directory.path), Set(contents) == ["original", "alternate"] else { return false }
        return [false, true].allSatisfy { alternate in
            let side = directory.appendingPathComponent(alternate ? "alternate" : "original")
            let names = Set(tiers.map { $0.identity(alternate: alternate).basename })
            return names.count == tiers.count &&
                tiers.allSatisfy { tierURL($0, alternate: alternate, in: directory) != nil } &&
                (try? Set(fm.contentsOfDirectory(atPath: side.path))) == names
        }
    }

    /// Called under the library lock, after the pair JSON no longer refers to retired generations.
    private func pruneGenerations(in directory: URL, keeping generation: UUID? = nil) {
        guard let ownerDirectory = optimizationOwner(in: directory) else { return }
        PathSafety.pruneDirectories(in: ownerDirectory, prefix: Self.generationPrefix, keeping: generation)
    }

    func rename(to name: String, in directory: URL) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try Self.update(in: directory) { pairs in
            guard deletionPending != true, let index = pairs.firstIndex(of: self) else { throw PairIssue.changed }
            pairs[index].name = trimmed
        }
    }

    /// Persist the confirmed IDs before removing either directory so a restart can finish the same deletion.
    func remove(in directory: URL) throws {
        try Self.withLibraryLock(in: directory) {
            try removeWhileLocked(in: directory, pairs: Self.read(in: directory))
        }
    }

    func removeWhileLocked(in directory: URL, pairs: [Self]) throws {
        var pairs = pairs
        guard let index = pairs.firstIndex(of: self) else { throw PairIssue.changed }
        let directories = try memberDirectories(in: directory)
        pairs[index].deletionPending = true
        try Self.write(pairs, in: directory)
        try Self.removeDirectories(directories)
        pairs.remove(at: index)
        try Self.write(pairs, in: directory)
    }

    func splitWhileLocked(in directory: URL, pairs: [Self]) throws {
        guard deletionPending != true, pairs.contains(self) else { throw PairIssue.changed }
        try Self.write(pairs.filter { $0 != self }, in: directory)
        pruneGenerations(in: directory)
    }

    private func memberDirectories(in directory: URL) throws -> [URL] {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        return try [owner, counterpart].map { id in
            let url = directory.appendingPathComponent(id)
            guard PathSafety.isValidEntryID(id), PathSafety.contained(url, in: directory) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return url
        }
    }

    func finishDeletion(in directory: URL) throws {
        try Self.update(in: directory) { pairs in
            guard let index = pairs.firstIndex(where: { $0.owner == owner && $0.counterpart == counterpart && $0.deletionPending == true }) else { return }
            try Self.removeDirectories(memberDirectories(in: directory))
            pairs.remove(at: index)
        }
    }

    private static func removeDirectories(_ directories: [URL]) throws {
        for url in directories {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            }
        }
    }
}

extension PathSafety {
    nonisolated static func isItem(at url: URL, ofType type: FileAttributeType) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == type
    }

    /// Only reclaim private UUID directories while their publisher holds the library lock.
    nonisolated static func pruneDirectories(in directory: URL, prefix: String, keeping generation: UUID? = nil) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
                  id != generation, isItem(at: url, ofType: .typeDirectory) else { continue }
            try? fm.removeItem(at: url)
        }
    }
}

nonisolated enum PairIssue: LocalizedError {
    case alreadyPaired
    case changed
    case tracks
    case timeline
    case color
    case format
    case reordering
    case sync

    var isCompatibilityIssue: Bool {
        switch self {
        case .tracks, .timeline, .color, .format, .reordering, .sync: true
        case .changed, .alreadyPaired: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .alreadyPaired: String(localized: "Split the existing pair before changing either video.")
        case .changed: String(localized: "The selection changed. Close this sheet and select the videos again.")
        case .tracks: String(localized: "Use one video track per file, with a full-length, untrimmed timeline.")
        case .timeline: String(localized: "Export both videos with the same constant frame rate, frame count, and loop duration.")
        case .color: String(localized: "Export both videos with an explicit SDR, HLG, or PQ color profile.")
        case .format: String(localized: "Match the dimensions, orientation, codec settings, and color profile of both exports.")
        case .reordering: String(localized: "Export both videos without frame reordering (B-frames).")
        case .sync: String(localized: "Align independent keyframes at the start and at least every half second. Use closed GOPs in both exports.")
        }
    }
}
