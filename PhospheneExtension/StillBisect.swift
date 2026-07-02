import AVFoundation
import CoreMedia
import QuartzCore

enum Bisect {
    /// Read per-acquire (a cheap stat) so the mode can be flipped by adding/removing the
    /// marker file and relaunching the Agent — no rebuild.
    static var stillOnly: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/BISECT_STILL")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// One still-hosting layer per display. Touched ONLY on `Lifecycle.queue`.
    nonisolated(unsafe) static var stillLayers: [DisplayKey: AVSampleBufferDisplayLayer] = [:]
}

/// Put a single still frame on the display's root layer (creating/reusing one AVSBDL per
/// display). The frame is the choice's cached BMP snapshot if present, else one decoded
/// video frame — either way IOSurface-backed so it composites in the Agent's CALayerHost
/// (a plain `CALayer.contents` does not). Tagged `DisplayImmediately` so a switch replaces
/// the prior still with no flush. Must run on `Lifecycle.queue`.
func bisectShowStill(videoURL: URL?, cachedStill: CGImage?, rootLayer: CALayer, for key: DisplayKey) {
    let layer: AVSampleBufferDisplayLayer
    if let existing = Bisect.stillLayers[key] {
        layer = existing
    } else {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = rootLayer.bounds
        layer.contentsScale = rootLayer.contentsScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(layer)
        CATransaction.commit()
        CATransaction.flush()
        Bisect.stillLayers[key] = layer
    }

    var sample: CMSampleBuffer?
    var source = "none"
    if let cachedStill, let buf = makeStillSampleBuffer(from: cachedStill) {
        sample = buf
        source = "cachedBMP"
    } else if let videoURL, let buf = decodeFirstSampleBuffer(videoURL) {
        sample = buf
        source = "decodedFrame"
    }
    guard let sample else {
        extensionLog("  [bisect] display \(key.displayID): NO still available (cachedStill=\(cachedStill != nil), url=\(videoURL?.lastPathComponent ?? "nil"))")
        return
    }
    bisectSetDisplayImmediately(sample)
    layer.sampleBufferRenderer.enqueue(sample)
    extensionLog("  [bisect] display \(key.displayID): enqueued still (src=\(source))")
}

/// Decode exactly one frame from a video — no reader kept, no feed loop. Blocks the
/// caller (`Lifecycle.queue`) briefly, like the video path's blocking track load.
private func decodeFirstSampleBuffer(_ url: URL) -> CMSampleBuffer? {
    let asset = AVURLAsset(url: url)
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var track: AVAssetTrack?
    asset.loadTracks(withMediaType: .video) { tracks, _ in
        track = tracks?.first
        sem.signal()
    }
    sem.wait()
    guard let track, let reader = try? AVAssetReader(asset: asset) else { return nil }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.startReading()
    return output.copyNextSampleBuffer()
}

/// Tag a sample buffer for immediate display (replaces the currently displayed image
/// regardless of timestamps). Local copy of the renderer's helper so this diagnostic is
/// fully self-contained.
private func bisectSetDisplayImmediately(_ sample: CMSampleBuffer) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
    for i in 0 ..< CFArrayGetCount(attachments) {
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
        )
    }
}
