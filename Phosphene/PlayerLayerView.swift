import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// An AVPlayerLayer host for the Library's on-demand live previews
/// (hover playback in the grid, the inspector player).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var hdrMode: HDRMode = WallpaperPrefsService.shared.hdrMode

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.preferredDynamicRange = hdrMode.dynamicRange
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = view.bounds
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        if let viewLayer = view.layer {
            viewLayer.addSublayer(playerLayer)
            context.coordinator.playerLayer = playerLayer
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let playerLayer = context.coordinator.playerLayer {
            // SwiftUI keeps this view when its player is swapped for another.
            if playerLayer.player !== player {
                playerLayer.player = player
            }
            playerLayer.preferredDynamicRange = hdrMode.dynamicRange
            let newFrame = nsView.bounds
            if newFrame != playerLayer.frame {
                playerLayer.frame = newFrame
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator {
        var playerLayer: AVPlayerLayer?
    }
}

/// Both players render into the full preview bounds. The second stream is clipped in layer coordinates.
struct PairPlayerLayerView: NSViewRepresentable {
    let playback: PairPlayback
    let swapped: Bool
    let fraction: CGFloat
    var hdrMode: HDRMode = WallpaperPrefsService.shared.hdrMode

    func makeNSView(context _: Context) -> Surface {
        Surface()
    }

    func updateNSView(_ view: Surface, context _: Context) {
        view.update(playback: playback, swapped: swapped, fraction: fraction, hdrMode: hdrMode)
    }

    static func dismantleNSView(_ view: Surface, coordinator _: ()) {
        view.detachPlayers()
    }

    final class Surface: NSView {
        private let first = AVPlayerLayer()
        private let second = AVPlayerLayer()
        private let clip = CALayer()
        private var readiness: [NSKeyValueObservation] = []
        private var swapped = false
        private var fraction: CGFloat = 0.5

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            first.videoGravity = .resizeAspect
            second.videoGravity = .resizeAspect
            clip.masksToBounds = true
            clip.anchorPoint = .zero
            layer?.addSublayer(first)
            layer?.addSublayer(clip)
            clip.addSublayer(second)
            readiness = showWhenReady([first, second])
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        func update(playback: PairPlayback, swapped: Bool, fraction: CGFloat, hdrMode: HDRMode) {
            if first.player !== playback.first {
                first.player = playback.first
            }
            if second.player !== playback.second {
                second.player = playback.second
            }
            let dynamicRange = hdrMode.dynamicRange
            if first.preferredDynamicRange != dynamicRange {
                first.preferredDynamicRange = dynamicRange
                second.preferredDynamicRange = dynamicRange
            }
            self.swapped = swapped
            self.fraction = fraction
            layoutPlayers()
        }

        func detachPlayers() {
            first.player = nil
            second.player = nil
        }

        override func layout() {
            super.layout()
            layoutPlayers()
        }

        private func layoutPlayers() {
            let split = bounds.width * fraction
            let clipX = swapped ? 0 : split
            let clipWidth = swapped ? split : bounds.width - split
            let crop = CGRect(x: clipX, y: 0, width: clipWidth, height: bounds.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if first.frame != bounds {
                first.frame = bounds
            }
            if second.frame != bounds {
                second.frame = bounds
            }
            // Moving both origins crops the stream without moving its video layer.
            clip.bounds = crop
            clip.position = crop.origin
            CATransaction.commit()
        }
    }
}

/// Keep the posters visible until every stream has a frame, including the first frame after a source change.
@MainActor
private func showWhenReady(_ layers: [AVPlayerLayer]) -> [NSKeyValueObservation] {
    for layer in layers {
        layer.backgroundColor = NSColor.black.cgColor
        layer.isHidden = true
    }
    let updateVisibility: @MainActor @Sendable () -> Void = {
        let hidden = !layers.allSatisfy(\.isReadyForDisplay)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.isHidden = hidden
        }
        CATransaction.commit()
    }
    return layers.map { layer in
        layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, _ in
            Task { @MainActor in updateVisibility() }
        }
    }
}
