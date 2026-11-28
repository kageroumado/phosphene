import AppKit
import AVFoundation
import CoreVideo
import QuartzCore
import SwiftUI

/// Call in order on the renderer's serial queue. Pause the renderer for the synchronous capture in begin.
final nonisolated class AppearanceTransition {
    private var cover: CALayer?
    // SwiftUI's default spring on macOS 14 and later.
    private static let spring = Spring(response: 0.55, dampingRatio: 1)
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func fraction(from initial: Double, to target: Double, elapsed: TimeInterval) -> Double {
        min(1, max(0, initial + spring.value(target: target - initial, time: elapsed)))
    }

    /// The remote layer and snapshot requests sample the same host-clock spring.
    struct Fade {
        let start: TimeInterval
        let from: Double
        let to: Double
        let duration: TimeInterval

        init(start: TimeInterval, from: Double, to: Double) {
            self.start = start
            self.from = from
            self.to = to
            duration = !reduceMotion && abs(from - to) > 0.001
                ? spring.settlingDuration(fromValue: from, toValue: to, initialVelocity: 0, epsilon: 0.001)
                : 0
        }

        func opacity(at time: TimeInterval) -> Double {
            guard time < start + duration else { return to }
            return fraction(from: from, to: to, elapsed: max(0, time - start))
        }

        func apply(to layer: CALayer) {
            updateLayers {
                layer.removeAnimation(forKey: "appearanceOpacity")
                layer.opacity = Float(to)
                guard duration > 0 else { return }
                let animation = CASpringAnimation(keyPath: "opacity")
                animation.mass = spring.mass
                animation.stiffness = spring.stiffness
                animation.damping = spring.damping
                animation.fromValue = from
                animation.toValue = to
                animation.beginTime = layer.convertTime(start, from: nil)
                animation.duration = duration
                layer.add(animation, forKey: "appearanceOpacity")
            }
        }
    }

    func begin(on displayLayer: AVSampleBufferDisplayLayer, renderer: AVSampleBufferVideoRenderer) {
        guard !Self.reduceMotion, let parent = displayLayer.superlayer,
              let pixels = renderer.displayedPixelBuffer(), unsafe CVPixelBufferGetIOSurface(pixels) != nil,
              let next = Self.makeCover(pixels, matching: displayLayer) else {
            cancel()
            return
        }
        // Commit the held image before the renderer can enqueue its replacement.
        Self.updateLayers {
            cover?.removeFromSuperlayer()
            parent.insertSublayer(next, above: displayLayer)
        }
        cover = next
    }

    func reveal(on queue: DispatchQueue) {
        guard let cover else { return }
        let fade = Fade(start: CACurrentMediaTime(), from: 1, to: 0)
        fade.apply(to: cover)
        queue.asyncAfter(deadline: .now() + fade.duration, execute: DispatchWorkItem { [weak self, weak cover] in
            guard let self, let cover, self.cover === cover else { return }
            cancel()
        })
    }

    func updateDynamicRange(_ dynamicRange: CALayer.DynamicRange) {
        guard let image = cover?.sublayers?.first else { return }
        Self.updateLayers { image.preferredDynamicRange = dynamicRange }
    }

    func cancel() {
        guard let cover else { return }
        Self.updateLayers { cover.removeFromSuperlayer() }
        self.cover = nil
    }

    private static func updateLayers(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
        CATransaction.flush()
    }

    private static func makeCover(_ pixels: CVPixelBuffer, matching source: AVSampleBufferDisplayLayer) -> CALayer? {
        let displaySize = CVImageBufferGetDisplaySize(pixels)
        let clean = CVImageBufferGetCleanRect(pixels)
        let encoded = CVImageBufferGetEncodedSize(pixels)
        let bounds = source.bounds
        guard displaySize.width > 0, displaySize.height > 0, encoded.width > 0, encoded.height > 0,
              clean.width > 0, clean.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }

        let cover = CALayer()
        cover.bounds = bounds
        cover.position = source.position
        cover.anchorPoint = source.anchorPoint
        cover.anchorPointZ = source.anchorPointZ
        cover.transform = source.transform
        cover.zPosition = source.zPosition
        cover.cornerRadius = source.cornerRadius
        cover.maskedCorners = source.maskedCorners
        cover.masksToBounds = true
        cover.backgroundColor = source.backgroundColor

        let image = CALayer()
        image.contentsScale = source.contentsScale
        // Keep the IOSurface-backed video planes and their color attachments together.
        image.contents = pixels
        image.contentsRect = CGRect(
            x: clean.minX / encoded.width, y: 1 - clean.maxY / encoded.height,
            width: clean.width / encoded.width, height: clean.height / encoded.height,
        )
        image.preferredDynamicRange = source.preferredDynamicRange
        // Both video layers use resizeAspectFill.
        let scale = max(bounds.width / displaySize.width, bounds.height / displaySize.height)
        let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
        image.frame = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
        cover.addSublayer(image)
        return cover
    }
}
