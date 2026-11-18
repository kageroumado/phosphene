import AVFoundation
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
            if playerLayer.player !== player { playerLayer.player = player }
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
