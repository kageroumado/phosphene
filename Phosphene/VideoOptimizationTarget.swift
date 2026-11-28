import Foundation

struct VideoOptimizationTarget {
    let entry: VideoDeploymentService.EntryInfo
    let pair: VideoPairSelection?

    var id: String {
        pair?.id ?? entry.id
    }

    var storedTiers: [(fps: Int, resolution: CGSize)] {
        if let record = pair?.saved {
            return record.optimization?.tiers.map { ($0.fps, $0.resolution) } ?? []
        }
        return entry.variants?.map { ($0.fps, $0.resolution) } ?? []
    }

    var tiers: [(fps: Int, resolution: CGSize)] {
        if pair?.saved != nil {
            return storedTiers
        }
        return playableVariants.map { ($0.fps, $0.resolution) }
    }

    private var playableVariants: [VideoVariant] {
        let library = VideoDeploymentService.videosFolderURL
        let directory = library.appendingPathComponent(entry.id, isDirectory: true)
        return (entry.variants ?? []).filter {
            $0.supports(sourceIsHDR: entry.sourceIsHDR) && $0.isAvailable(in: directory, library: library)
        }
    }

    var convertedToSDR: Bool {
        if let record = pair?.saved {
            return record.optimization?.toneMappedToSDR == true
        }
        return playableVariants.contains { $0.toneMappedToSDR == true }
    }

    var eligibilityError: (any Error)? {
        guard let pair else {
            return VideoOptimizationService.resolutionError(entry.resolution)
        }
        guard pair.members.count == 2, let record = pair.saved, record.deletionPending != true else { return PairIssue.changed }
        guard pair.members.allSatisfy({ $0.sourceIsHDR != nil }) else {
            return VideoOptimizationService.OptimizationError.unsupportedDynamicRange
        }
        return pair.members.lazy.compactMap { VideoOptimizationService.resolutionError($0.resolution) }.first
    }

    func optimize(
        preset: OptimizationPreset, convertToSDR: Bool,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws {
        let files = FileManager.default
        let library = VideoDeploymentService.videosFolderURL
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: library, create: true)
        defer { try? files.removeItem(at: work) }

        let targetSize = preset.targetResolution(source: entry.resolution)
        let source = VideoDeploymentService.videoURL(for: entry)
        guard let identity = FileIdentity(of: source) else { throw CocoaError(.fileNoSuchFile) }

        guard let pair else {
            try AppearancePair.requireSingle(id, in: library)
            let result = try await VideoOptimizationService.createVariants(
                sourceURL: source, sourceIsHDR: entry.sourceIsHDR, targetResolution: targetSize,
                outputDirectory: work, convertToSDR: convertToSDR, progress: progress,
            )
            try Task.checkCancellation()
            try VideoDeploymentService.deployVariants(
                entryID: id, source: identity, sourceIsHDR: result.sourceIsHDR, variants: result.variants,
            )
            return
        }

        guard let record = pair.saved, let second = pair.second, entry.id == record.owner, second.id == record.counterpart,
              identity == record.validation.original else { throw PairIssue.changed }
        guard let sourceIsHDR = entry.sourceIsHDR, let alternateIsHDR = second.sourceIsHDR else {
            throw VideoOptimizationService.OptimizationError.unsupportedDynamicRange
        }
        let alternate = VideoDeploymentService.videoURL(for: second)
        guard FileIdentity(of: alternate) == record.validation.alternate else { throw PairIssue.changed }
        let originalDir = work.appendingPathComponent("original", isDirectory: true)
        let alternateDir = work.appendingPathComponent("alternate", isDirectory: true)
        try files.createDirectory(at: originalDir, withIntermediateDirectories: false)
        try files.createDirectory(at: alternateDir, withIntermediateDirectories: false)
        let (_, originalTiers) = try await VideoOptimizationService.createVariants(
            sourceURL: source, sourceIsHDR: sourceIsHDR, targetResolution: targetSize,
            outputDirectory: originalDir, forPair: true, convertToSDR: convertToSDR,
        ) { progress($0 * 0.45) }
        try Task.checkCancellation()
        let (_, alternateTiers) = try await VideoOptimizationService.createVariants(
            sourceURL: alternate, sourceIsHDR: alternateIsHDR, targetResolution: targetSize,
            outputDirectory: alternateDir, forPair: true, convertToSDR: convertToSDR,
        ) { progress(0.45 + $0 * 0.45) }
        guard originalTiers.count == alternateTiers.count else { throw PairIssue.timeline }
        var tiers = [AppearancePair.Tier]()
        for (original, alternate) in zip(originalTiers, alternateTiers) {
            try Task.checkCancellation()
            guard original.variant.fps == alternate.variant.fps, original.variant.resolution == alternate.variant.resolution,
                  original.variant.isHDR == alternate.variant.isHDR else { throw PairIssue.format }
            let validation = try await PairEligibility.validate(original.url, alternate.url)
            tiers.append(.init(fps: original.variant.fps, resolution: original.variant.resolution, validation: validation))
            progress(0.9 + 0.1 * Double(tiers.count) / Double(originalTiers.count))
        }
        try Task.checkCancellation()
        guard !tiers.isEmpty else { return }
        let staging = library.appendingPathComponent(".optimization-" + UUID().uuidString, isDirectory: true)
        try files.moveItem(at: work, to: staging)
        defer { try? files.removeItem(at: staging) }
        try VideoDeploymentService.deployPairVariants(pair: record, directory: staging, tiers: tiers, convertToSDR: convertToSDR)
    }
}
