import AVFoundation

nonisolated enum PairEligibility {
    private struct Track {
        let cursor: AVSampleCursor
        let duration: CMTime
        let transform: CGAffineTransform
        let isHDR: Bool

        init(url: URL) async throws {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard tracks.count == 1, let track = tracks.first, try await asset.load(.providesPreciseDurationAndTiming),
                  try await track.load(.isEnabled), let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder()
            else { throw PairIssue.tracks }
            let duration = try await asset.load(.duration)
            let full = CMTimeRange(start: .zero, duration: duration)
            let segments = try await track.load(.segments)
            guard duration.isNumeric, duration > .zero, try await track.load(.timeRange) == full,
                  segments.count == 1, let mapping = segments.first?.timeMapping,
                  mapping.source == full, mapping.target == full else { throw PairIssue.tracks }
            guard let isHDR = await VideoProbe.classify(track) else { throw PairIssue.color }
            self.isHDR = isHDR
            self.duration = duration
            self.cursor = cursor
            self.transform = try await track.load(.preferredTransform)
        }
    }

    @concurrent
    static func validate(_ original: URL, _ alternate: URL) async throws -> AppearancePair.Validation {
        guard let first = FileIdentity(of: original), let second = FileIdentity(of: alternate) else { throw PairIssue.changed }
        let a = try await Track(url: original)
        let b = try await Track(url: alternate)
        guard a.duration == b.duration else { throw PairIssue.timeline }
        guard a.isHDR == b.isHDR, a.transform == b.transform else { throw PairIssue.format }
        let x = a.cursor, y = b.cursor
        let step = x.currentSampleDuration
        let format = x.copyCurrentSampleFormatDescription()
        guard step.isNumeric, step > .zero else { throw PairIssue.timeline }
        let initialDTS = x.decodeTimeStamp
        let maxGap = CMTime(value: 1, timescale: 2)
        var common = [Int]()
        var count = 0
        var pts = CMTime.zero
        var lastSync = CMTime.zero
        while true {
            try Task.checkCancellation()
            try checkSample(x, y, format: format, step: step, pts: pts, initialDTS: initialDTS)
            guard pts - lastSync <= maxGap else { throw PairIssue.sync }
            if x.currentSampleSyncInfo.sampleIsFullSync.boolValue, y.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                common.append(count)
                lastSync = pts
            } else if count == 0 {
                throw PairIssue.sync
            }
            count += 1
            pts = CMTimeAdd(pts, step)
            let moved = x.stepInDecodeOrder(byCount: 1)
            guard y.stepInDecodeOrder(byCount: 1) == moved else { throw PairIssue.timeline }
            if moved == 0 {
                break
            }
            guard moved == 1, pts < a.duration else { throw PairIssue.timeline }
        }
        guard pts == a.duration else { throw PairIssue.timeline }
        guard pts - lastSync <= maxGap else { throw PairIssue.sync }
        guard FileIdentity(of: original) == first, FileIdentity(of: alternate) == second else { throw PairIssue.changed }
        return .init(original: first, alternate: second, frameTicks: step.value, timescale: step.timescale, frameCount: count, commonSyncFrames: common)
    }

    private static func checkSample(
        _ x: AVSampleCursor, _ y: AVSampleCursor, format: CMFormatDescription,
        step: CMTime, pts: CMTime, initialDTS: CMTime,
    ) throws {
        guard x.copyCurrentSampleFormatDescription() == format, y.copyCurrentSampleFormatDescription() == format else { throw PairIssue.format }
        guard x.currentSampleDuration == step, y.currentSampleDuration == step else { throw PairIssue.timeline }
        guard x.presentationTimeStamp == pts, y.presentationTimeStamp == pts else { throw PairIssue.reordering }
        let dx = x.decodeTimeStamp, dy = y.decodeTimeStamp
        guard (!initialDTS.isValid && !dx.isValid && !dy.isValid) ||
            (initialDTS.isNumeric && dx.isNumeric && dx == dy && dx == pts + initialDTS) else { throw PairIssue.reordering }
    }
}
