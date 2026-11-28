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

        func orderedMembers(of pair: AppearancePair) -> [(String, DeletionMember)] {
            [pair.owner, pair.counterpart].compactMap { id in members[id].map { (id, $0) } }
        }
    }

    private struct DeletionMember: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let media: FileIdentity

        init?(at directory: URL, media: FileIdentity, allowMissingMedia: Bool = false) throws {
            guard let attributes = try PathSafety.attributes(at: directory) else { return nil }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { throw PairIssue.changed }
            self.device = device
            self.inode = inode
            self.media = media
            guard PathSafety.isSafeComponent(media.basename) else { throw PairIssue.changed }
            if allowMissingMedia, try PathSafety.attributes(at: directory.appendingPathComponent(media.basename)) == nil {
                return nil
            }
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
            try Self.renameExclusively(from: source, to: staged)
            return true
        }

        static func renameExclusively(from source: URL, to destination: URL) throws {
            guard unsafe renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
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

    /// Confirm disk identities before offering to remove one member's inactive single-video tiers.
    func memberVariantRemoval(for id: String, in directory: URL) throws -> MemberVariantRemoval {
        try Self.withLibraryLock(in: directory) {
            let (source, _, _, variants) = try memberVariantSource(id, in: directory)
            let files = try Self.memberVariantFiles(variants, beside: source)
            guard !files.isEmpty else { throw PairIssue.changed }
            return MemberVariantRemoval(pair: self, id: id, variants: variants, files: files)
        }
    }

    private struct VariantMetadata: Decodable {
        let id: String
        let filename: String
        let variants: [VideoVariant]?
    }

    struct MemberVariantRemoval {
        fileprivate let pair: AppearancePair
        fileprivate let id: String
        fileprivate let variants: [VideoVariant]
        fileprivate let files: [String: FileIdentity?]

        var filenames: [String] {
            files.keys.sorted()
        }

        func remove(in directory: URL) throws {
            try AppearancePair.withLibraryLock(in: directory) {
                let (source, metadata, data, current) = try pair.memberVariantSource(id, in: directory)
                guard current == variants,
                      var record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawVariants = record["variants"] as? [[String: Any]] else { throw PairIssue.changed }
                let confirmed = try AppearancePair.memberVariantFiles(variants, beside: source)
                for (name, expected) in files {
                    guard let actual = confirmed[name], actual == nil || actual == expected else { throw PairIssue.changed }
                }
                for name in filenames {
                    let url = source.deletingLastPathComponent().appendingPathComponent(name)
                    guard let attributes = try PathSafety.attributes(at: url) else { continue }
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let expected = files[name] ?? nil,
                          FileIdentity(basename: name, attributes: attributes) == expected else { throw PairIssue.changed }
                    guard unsafe unlink(url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                }
                let remaining: [[String: Any]] = zip(variants, rawVariants).compactMap { variant, raw in
                    files.keys.contains(variant.filename) ? nil : raw
                }
                record["variants"] = remaining.isEmpty ? nil : remaining
                try JSONSerialization.data(withJSONObject: record).write(to: metadata, options: .atomic)
            }
        }
    }

    private func memberVariantSource(_ id: String, in directory: URL) throws -> (URL, URL, Data, [VideoVariant]) {
        guard contains(id), deletionPending != true, try Self.readForMutation(in: directory).contains(self) else { throw PairIssue.changed }
        let folder = directory.appendingPathComponent(id)
        let metadata = folder.appendingPathComponent("metadata.json")
        guard PathSafety.isItem(at: folder, ofType: .typeDirectory),
              PathSafety.isItem(at: metadata, ofType: .typeRegular) else { throw PairIssue.changed }
        let data = try Data(contentsOf: metadata)
        let entry = try JSONDecoder().decode(VariantMetadata.self, from: data)
        let expected = id == owner ? validation.original : validation.alternate
        guard entry.id == id, entry.filename == expected.basename, PathSafety.isSafeComponent(entry.filename) else { throw PairIssue.changed }
        let source = folder.appendingPathComponent(entry.filename)
        guard PathSafety.isItem(at: source, ofType: .typeRegular), FileIdentity(of: source) == expected else { throw PairIssue.changed }
        return (source, metadata, data, entry.variants ?? [])
    }

    private static func memberVariantFiles(_ variants: [VideoVariant], beside source: URL) throws -> [String: FileIdentity?] {
        let folder = source.deletingLastPathComponent()
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
        var files: [String: FileIdentity?] = [:]
        for variant in variants where variant.hasGeneratedFilename {
            let name = variant.filename
            guard name.caseInsensitiveCompare(source.lastPathComponent) != .orderedSame else { continue }
            let url = folder.appendingPathComponent(name)
            guard let attributes = try PathSafety.attributes(at: url) else {
                files.updateValue(nil, forKey: name)
                continue
            }
            guard names.contains(name), attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
                  let identity = FileIdentity(basename: name, attributes: attributes) else { continue }
            files[name] = identity
        }
        return files
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

    /// The owner directory can contain new or unrecognized files after its source disappears.
    private func removeRetiredTiers(in directory: URL) throws {
        guard let optimization else { return }
        let ownerDirectory = directory.appendingPathComponent(owner)
        guard try PathSafety.attributes(at: ownerDirectory)?[.type] as? FileAttributeType == .typeDirectory else { return }
        let generation = Self.generationURL(optimization.generation, under: ownerDirectory)
        guard try PathSafety.attributes(at: generation)?[.type] as? FileAttributeType == .typeDirectory else { return }
        for alternate in [false, true] {
            let side = generation.appendingPathComponent(alternate ? "alternate" : "original")
            guard try PathSafety.attributes(at: side)?[.type] as? FileAttributeType == .typeDirectory else { continue }
            for tier in optimization.tiers {
                let identity = tier.identity(alternate: alternate)
                guard PathSafety.isSafeComponent(identity.basename) else { continue }
                let url = side.appendingPathComponent(identity.basename)
                guard let attributes = try PathSafety.attributes(at: url), attributes[.type] as? FileAttributeType == .typeRegular,
                      FileIdentity(basename: identity.basename, attributes: attributes) == identity else { continue }
                guard unsafe unlink(url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            }
            try Self.removeEmptyDirectory(side)
        }
        try Self.removeEmptyDirectory(generation)
    }

    private static func removeEmptyDirectory(_ url: URL) throws {
        if unsafe rmdir(url.path) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            guard code == .ENOENT || code == .ENOTEMPTY else { throw POSIXError(code) }
        }
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
        let original = try DeletionMember(at: directory.appendingPathComponent(owner), media: validation.original, allowMissingMedia: true)
        let alternate = try DeletionMember(at: directory.appendingPathComponent(counterpart), media: validation.alternate, allowMissingMedia: true)
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

        do {
            for (id, member) in deletion.orderedMembers(of: self) {
                guard try member.detach(from: directory.appendingPathComponent(id), to: deletion.stagingURL(for: id, in: directory)) else {
                    throw PairIssue.changed
                }
            }
            // Keep staged originals recoverable while clearing tiers from a missing owner.
            if deletion.members[owner] == nil {
                try removeRetiredTiers(in: directory)
            }
            // Persist the commit before removing any staged data.
            pending[index].deletion?.detached = true
            try Self.write(pending, in: directory)
        } catch {
            try Self.rollbackDeletion(at: index, deletion: deletion, in: directory, pairs: pending)
            throw error
        }
        try Self.finishDeletion(at: index, in: directory, pairs: pending, recovering: false)
    }

    func finishDeletion(in directory: URL) throws {
        try Self.withLibraryLock(in: directory) {
            let pairs = try Self.readForMutation(in: directory)
            guard deletionPending == true, let index = pairs.firstIndex(where: {
                $0.deletionPending == true && $0.owner == owner && $0.counterpart == counterpart &&
                    $0.membershipID == membershipID && $0.deletion?.token == deletion?.token
            }) else { return }
            try Self.finishDeletion(at: index, in: directory.standardizedFileURL.resolvingSymlinksInPath(), pairs: pairs, recovering: true)
        }
    }

    private static func finishDeletion(at index: Int, in directory: URL, pairs: [Self], recovering: Bool) throws {
        var pairs = pairs
        let pair = pairs[index]
        // Legacy records have no removal-specific identities. Release any survivors untouched.
        guard let deletion = pair.deletion else {
            try pair.removeRetiredTiers(in: directory)
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
        guard deletion.detached else {
            try rollbackDeletion(at: index, deletion: deletion, in: directory, pairs: pairs)
            return
        }

        if recovering, deletion.members[pair.owner] == nil {
            try pair.removeRetiredTiers(in: directory)
        }
        for (id, member) in deletion.orderedMembers(of: pair) {
            let staged = deletion.stagingURL(for: id, in: directory)
            if try PathSafety.attributes(at: staged) != nil {
                guard try member.matchesDirectory(staged) else { throw PairIssue.changed }
                if try PathSafety.attributes(at: staged.appendingPathComponent(member.media.basename)) != nil {
                    guard try member.matchesMedia(in: staged) else { throw PairIssue.changed }
                }
                try FileManager.default.removeItem(at: staged)
            }
        }
        pairs.remove(at: index)
        try write(pairs, in: directory)
    }

    private static func rollbackDeletion(at index: Int, deletion: Deletion, in directory: URL, pairs: [Self]) throws {
        var pairs = pairs
        var failure: (any Error)?
        for (id, member) in deletion.orderedMembers(of: pairs[index]).reversed() {
            let staged = deletion.stagingURL(for: id, in: directory)
            do {
                guard try member.matchesDirectory(staged) else { continue }
                try DeletionMember.renameExclusively(from: staged, to: directory.appendingPathComponent(id))
            } catch {
                failure = failure ?? error
            }
        }
        // Leave the rollback record in place when a replacement occupies a restore path.
        if let failure {
            throw failure
        }
        pairs[index].deletionPending = nil
        pairs[index].deletion = nil
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
