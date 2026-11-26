import AVFoundation

struct PairRendition: Sendable {
    let pair: AppearancePair
    let originals: Playback
    private let directory: URL

    init?(_ pair: AppearancePair, library: VideoLibrary) {
        guard let first = library.videoURL(for: pair.owner), let second = library.videoURL(for: pair.counterpart),
              pair.deletionPending != true,
              let originals = Playback(original: first, alternate: second, validation: pair.validation) else { return nil }
        self.pair = pair
        self.originals = originals
        directory = library.videosDir
    }

    func url(dark: Bool) -> URL {
        url(dark: dark, in: originals)
    }

    func url(dark: Bool, in playback: Playback) -> URL {
        dark != pair.swapped ? playback.alternate : playback.original
    }

    func playback(for policy: PlaybackPolicy) -> Playback {
        guard policy != .paused else { return originals }
        let fps = Int((Double(pair.validation.timescale) / Double(pair.validation.frameTicks)).rounded())
        return VariantSelection.tier(for: policy, sourceFPS: fps, tiers: pair.optimization?.tiers ?? [], fps: \.fps)
            .flatMap(optimizedPlayback(for:)) ?? originals
    }

    func retains(_ playback: Playback) -> Bool {
        guard originals.filesMatch else { return false }
        return playback == originals || pair.optimization?.tiers.contains { tier in
            tier.validation == playback.validation && optimizedPlayback(for: tier) == playback
        } == true
    }

    private func optimizedPlayback(for tier: AppearancePair.Tier) -> Playback? {
        guard originals.filesMatch,
              let first = pair.optimizedURL(for: tier, alternate: false, in: directory),
              let second = pair.optimizedURL(for: tier, alternate: true, in: directory) else { return nil }
        return Playback(original: first, alternate: second, validation: tier.validation)
    }

    struct Playback: Equatable, Sendable {
        let original: URL
        let alternate: URL
        let validation: AppearancePair.Validation

        init?(original: URL, alternate: URL, validation: AppearancePair.Validation) {
            guard validation.version == 1, validation.frameTicks > 0, validation.timescale > 0,
                  validation.frameCount > 0, Int64(validation.frameCount) <= Int64.max / validation.frameTicks,
                  validation.commonSyncFrames.first == 0, original != alternate else { return nil }
            self.original = original
            self.alternate = alternate
            self.validation = validation
            guard filesMatch else { return nil }
        }

        var filesMatch: Bool {
            FileIdentity(of: original) == validation.original && FileIdentity(of: alternate) == validation.alternate
        }

        func identity(for url: URL) -> FileIdentity? {
            if url == original {
                return validation.original
            }
            if url == alternate {
                return validation.alternate
            }
            return nil
        }

        func nextCut(frontier: CMTime, loopStart: CMTime) -> (local: CMTime, global: CMTime)? {
            let v = validation
            func time(_ frame: Int) -> CMTime {
                CMTime(value: Int64(frame) * v.frameTicks, timescale: v.timescale)
            }
            let earliest = frontier - loopStart + CMTimeMinimum(CMTime(value: 1, timescale: 8), time(v.frameCount))
            guard let index = v.commonSyncFrames.first(where: { (0 ..< v.frameCount).contains($0) && time($0) >= earliest }) else { return nil }
            let local = time(index)
            return (local, loopStart + local)
        }
    }
}

/// The preparation task hands this reader to the serial render queue exactly once.
final class PreparedAppearanceCut: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let first: CMSampleBuffer
    let at: CMTime

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, first: CMSampleBuffer, at: CMTime) {
        self.reader = reader
        self.output = output
        self.first = first
        self.at = at
    }

    static func prepare(url: URL, local: CMTime, at: CMTime, identity: FileIdentity) async -> PreparedAppearanceCut? {
        let asset = AVURLAsset(url: url)
        guard FileIdentity(of: url) == identity, let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset), !Task.isCancelled else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(start: local, duration: .positiveInfinity)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        while !Task.isCancelled, let sample = output.copyNextSampleBuffer() {
            if sample.numSamples == 0 || sample.presentationTimeStamp < local {
                continue
            }
            guard !Task.isCancelled, sample.numSamples == 1, sample.presentationTimeStamp == local,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [[CFString: Any]],
                  attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true, FileIdentity(of: url) == identity else { break }
            return PreparedAppearanceCut(reader: reader, output: output, first: sample, at: at)
        }
        reader.cancelReading()
        return nil
    }
}

/// Compressed samples in local track time, with the reader positioned after the visible frame.
final class PreparedPausedAppearance: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let loopStart: CMTime
    let preroll: [CMSampleBuffer]
    let frame: CMSampleBuffer

    private init(cut: PreparedAppearanceCut, loopStart: CMTime, preroll: [CMSampleBuffer], frame: CMSampleBuffer) {
        reader = cut.reader
        output = cut.output
        self.loopStart = loopStart
        self.preroll = preroll
        self.frame = frame
    }

    /// Use a known loop boundary when earlier playback tiers had a different loop duration.
    @concurrent
    static func prepare(
        playback: PairRendition.Playback,
        url: URL,
        at global: CMTime,
        loopStart origin: CMTime = .zero,
    ) async -> PreparedPausedAppearance? {
        guard !Task.isCancelled, global.isNumeric, origin.isNumeric, global.epoch == 0, origin.epoch == 0,
              global.timescale > 0, origin.timescale > 0, origin.value >= 0,
              let identity = playback.identity(for: url), playback.filesMatch else { return nil }
        let v = playback.validation
        // Convert the difference to track ticks without rounding the two clocks before subtraction.
        let elapsed = Int128(global.value) * Int128(origin.timescale) - Int128(origin.value) * Int128(global.timescale)
        let scale = Int128(global.timescale) * Int128(origin.timescale)
        guard elapsed >= 0, let ticks = Int64(exactly: elapsed * Int128(v.timescale) / scale) else { return nil }
        let localTicks = ticks % (Int64(v.frameCount) * v.frameTicks)
        let loopStart = origin + CMTime(value: ticks - localTicks, timescale: v.timescale)
        let target = Int(localTicks / v.frameTicks)
        guard let sync = v.commonSyncFrames.last(where: { (0 ... target).contains($0) }) else { return nil }
        func time(_ index: Int) -> CMTime {
            CMTime(value: Int64(index) * v.frameTicks, timescale: v.timescale)
        }

        let local = time(sync)
        let cutTime = loopStart + local
        guard cutTime.isNumeric, let cut = await PreparedAppearanceCut.prepare(url: url, local: local, at: cutTime, identity: identity) else { return nil }
        var handedOff = false
        defer {
            if !handedOff {
                cut.reader.cancelReading()
            }
        }
        guard let format = cut.first.formatDescription else { return nil }
        let firstDTS = cut.first.decodeTimeStamp
        let duration = time(1)
        var sample = cut.first
        var preroll: [CMSampleBuffer] = []
        for index in sync ... target {
            if index > sync {
                repeat {
                    guard !Task.isCancelled, let next = cut.output.copyNextSampleBuffer() else { return nil }
                    sample = next
                } while sample.numSamples == 0
            }
            let dts = sample.decodeTimeStamp
            guard !Task.isCancelled, sample.numSamples == 1, sample.presentationTimeStamp == time(index),
                  sample.duration == duration, sample.formatDescription == format,
                  (!firstDTS.isValid && !dts.isValid) ||
                  (firstDTS.isNumeric && dts.isNumeric && dts - firstDTS == time(index - sync)) else { return nil }
            if index < target {
                preroll.append(sample)
            }
        }
        guard playback.filesMatch, !Task.isCancelled else { return nil }
        handedOff = true
        return PreparedPausedAppearance(cut: cut, loopStart: loopStart, preroll: preroll, frame: sample)
    }
}

struct VideoSourceSelection: Sendable {
    let choice: String?
    let fallback: URL
    let fallbackIdentity: FileIdentity?
    let pair: PairRendition?

    init(choice: String?, fallback: URL) {
        self.choice = choice
        self.fallback = fallback
        fallbackIdentity = FileIdentity(of: fallback)
        pair = choice.flatMap { VideoLibrary.shared.pairRendition(for: $0) }
    }

    func variant(for policy: PlaybackPolicy) -> URL {
        guard let choice, VideoLibrary.shared.videoURL(for: choice) == fallback else { return fallback }
        return VideoLibrary.shared.bestVariantURL(for: choice, policy: policy) ?? fallback
    }
}
