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
    private var deletion: Deletion? = nil

    private struct Deletion: Codable, Equatable, Sendable {
        var token = UUID()
        let members: [String: DeletionMember]
        var split = false
        var detached = false

        func stagingURL(for id: String, in directory: URL) -> URL {
            directory.appendingPathComponent(".delete-\(token.uuidString)-\(id)")
        }
    }

    private struct DeletionMember: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let media: FileIdentity

        init?(at directory: URL, media: FileIdentity) throws {
            guard let attributes = try PathSafety.attributes(at: directory) else { return nil }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { throw PairIssue.changed }
            self.device = device
            self.inode = inode
            self.media = media
            guard try matchesMedia(in: directory) else { throw PairIssue.changed }
        }

        func matchesDirectory(_ directory: URL) throws -> Bool {
            guard let attributes = try PathSafety.attributes(at: directory) else { return false }
            return attributes[.type] as? FileAttributeType == .typeDirectory &&
                (attributes[.systemNumber] as? NSNumber)?.uint64Value == device &&
                (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == inode
        }

        func matchesMedia(in directory: URL) throws -> Bool {
            guard PathSafety.isSafeComponent(media.basename),
                  let attributes = try PathSafety.attributes(at: directory.appendingPathComponent(media.basename)),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return false }
            return FileIdentity(basename: media.basename, attributes: attributes) == media
        }

        func detach(from source: URL, to staged: URL) throws -> Bool {
            guard try matchesDirectory(source), try matchesMedia(in: source) else { return false }
            guard unsafe renamex_np(source.path, staged.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            return true
        }
    }

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

    /// Corrupt membership is empty for choice lookup and single-entry operations.
    static func read(in directory: URL) throws -> [Self] {
        do {
            return try readForMutation(in: directory)
        } catch is DecodingError {
            return []
        } catch let error as CocoaError where error.code == .fileReadCorruptFile {
            return []
        }
    }

    private static func readForMutation(in directory: URL) throws -> [Self] {
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
            var pairs = try readForMutation(in: directory)
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
            var pairs = try Self.readForMutation(in: directory)
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

    /// Persist the confirmed identities before detaching either member.
    func remove(in directory: URL) throws {
        try Self.withLibraryLock(in: directory) {
            try removeWhileLocked(in: directory, pairs: Self.readForMutation(in: directory))
        }
    }

    func removeWhileLocked(in directory: URL, pairs: [Self]) throws {
        guard owner != counterpart, [owner, counterpart].allSatisfy(PathSafety.isValidEntryID) else { throw PairIssue.changed }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let original = try DeletionMember(at: directory.appendingPathComponent(owner), media: validation.original)
        let alternate = try DeletionMember(at: directory.appendingPathComponent(counterpart), media: validation.alternate)
        let members = [owner: original, counterpart: alternate].compactMapValues { $0 }
        try beginDeletion(Deletion(members: members), in: directory, pairs: pairs)
    }

    func removeDegradedWhileLocked(_ id: String, media: FileIdentity, in directory: URL, pairs: [Self]) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(id), PathSafety.isValidEntryID(id),
              let member = try DeletionMember(at: directory.appendingPathComponent(id), media: media) else {
            throw PairIssue.changed
        }
        try beginDeletion(Deletion(members: [id: member], split: true), in: directory, pairs: pairs)
    }

    private func beginDeletion(_ deletion: Deletion, in directory: URL, pairs: [Self]) throws {
        guard deletionPending != true, let index = pairs.firstIndex(of: self) else { throw PairIssue.changed }
        var pending = pairs
        pending[index].deletionPending = true
        pending[index].deletion = deletion
        try Self.write(pending, in: directory)

        if deletion.split, let (id, member) = deletion.members.first {
            do {
                guard try member.detach(from: directory.appendingPathComponent(id), to: deletion.stagingURL(for: id, in: directory)) else {
                    throw PairIssue.changed
                }
            } catch {
                // A failed rename leaves the visible entry and all its tiers intact.
                try? Self.write(pairs, in: directory)
                throw error
            }
        }
        try Self.finishDeletion(at: index, in: directory, pairs: pending)
    }

    func finishDeletion(in directory: URL) throws {
        try Self.withLibraryLock(in: directory) {
            let pairs = try Self.readForMutation(in: directory)
            guard deletionPending == true, let index = pairs.firstIndex(where: {
                $0.deletionPending == true && $0.owner == owner && $0.counterpart == counterpart &&
                    $0.membershipID == membershipID && $0.deletion?.token == deletion?.token
            }) else { return }
            try Self.finishDeletion(at: index, in: directory.standardizedFileURL.resolvingSymlinksInPath(), pairs: pairs)
        }
    }

    private static func finishDeletion(at index: Int, in directory: URL, pairs: [Self]) throws {
        var pairs = pairs
        let pair = pairs[index]
        // Legacy records have no removal-specific identities. Release any survivors untouched.
        guard var deletion = pair.deletion else {
            pairs.remove(at: index)
            try write(pairs, in: directory)
            return
        }
        guard deletion.members.keys.allSatisfy(pair.contains),
              !deletion.split || deletion.members.count == 1,
              deletion.members.allSatisfy({ id, member in
                  PathSafety.isSafeComponent(member.media.basename) &&
                      (deletion.split || member.media == (id == pair.owner ? pair.validation.original : pair.validation.alternate))
              }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let members = [pair.owner, pair.counterpart].compactMap { id in deletion.members[id].map { (id, $0) } }
        if !deletion.detached {
            for (id, member) in members {
                let staged = deletion.stagingURL(for: id, in: directory)
                if try PathSafety.attributes(at: staged) == nil {
                    if deletion.split {
                        // A degraded removal that never detached must keep its membership and tiers.
                        pairs[index].deletionPending = nil
                        pairs[index].deletion = nil
                        try write(pairs, in: directory)
                        return
                    }
                    guard try member.detach(from: directory.appendingPathComponent(id), to: staged) else { continue }
                }
                guard try member.matchesDirectory(staged), try member.matchesMedia(in: staged) else { throw PairIssue.changed }
            }
            // A later cleanup attempt may find a staged directory whose media was already removed.
            deletion.detached = true
            pairs[index].deletion = deletion
            try write(pairs, in: directory)
        }

        for (id, member) in members {
            let staged = deletion.stagingURL(for: id, in: directory)
            if try PathSafety.attributes(at: staged) != nil {
                guard try member.matchesDirectory(staged) else { throw PairIssue.changed }
                try FileManager.default.removeItem(at: staged)
            }
        }
        pairs.remove(at: index)
        try write(pairs, in: directory)
    }
}

extension PathSafety {
    nonisolated static func attributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

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
