import AVFoundation
import CoreMedia
import Foundation

@MainActor
final class PairPlayback {
    let first: AVPlayer
    let second: AVPlayer

    private var players: [AVPlayer] {
        [first, second]
    }

    init(first: URL, second: URL) {
        self.first = Self.makePlayer(url: first)
        self.second = Self.makePlayer(url: second)
    }

    func run() async {
        defer { stop() }
        await withTaskCancellationHandler {
            do {
                guard try await waitUntilReady() else { return }
                while !Task.isCancelled, await playCycle() {
                    players.forEach { $0.pause() }
                }
            } catch {
                return
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    private static func makePlayer(url: URL) -> AVPlayer {
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.sourceClock = CMClock.hostTimeClock
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        return player
    }

    private func waitUntilReady() async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !players.allSatisfy({ $0.status == .readyToPlay && $0.currentItem?.status == .readyToPlay }) {
            guard ContinuousClock.now < deadline,
                  players.allSatisfy({ $0.status != .failed && $0.currentItem != nil && $0.currentItem?.status != .failed })
            else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func playCycle() async -> Bool {
        async let firstReady = Self.prepare(first)
        async let secondReady = Self.prepare(second)
        guard await (firstReady, secondReady) == (true, true), !Task.isCancelled else { return false }

        let center = NotificationCenter.default
        let (finished, continuation) = AsyncStream.makeStream(of: Bool.self)
        let end = AVPlayerItem.didPlayToEndTimeNotification
        let observers = players.compactMap(\.currentItem).flatMap { item in
            [end, AVPlayerItem.failedToPlayToEndTimeNotification, AVPlayerItem.playbackStalledNotification].map { name in
                center.addObserver(forName: name, object: item, queue: nil) { _ in
                    continuation.yield(name == end)
                }
            }
        }
        defer { observers.forEach(center.removeObserver) }

        // Both streams start from the same media time on the same clock, including after a loop.
        let start = CMClock.hostTimeClock.time + CMTime(value: 1, timescale: 20)
        for player in players {
            player.setRate(1, time: .zero, atHostTime: start)
        }
        var iterator = finished.makeAsyncIterator()
        return await iterator.next() == true
    }

    private static func prepare(_ player: AVPlayer) async -> Bool {
        guard !Task.isCancelled,
              await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero),
              !Task.isCancelled, player.status == .readyToPlay else { return false }
        return await player.preroll(atRate: 1)
    }

    private func stop() {
        for player in players where player.currentItem != nil {
            player.pause()
            player.cancelPendingPrerolls()
            player.currentItem?.cancelPendingSeeks()
            player.replaceCurrentItem(with: nil)
        }
    }
}
