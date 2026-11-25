import Tiptoe

/// Coordinates Phosphene's calls into TiptoeGitHub, including admission to video work.
@MainActor
final class UpdateActivity {
    enum ManualResult: Equatable {
        case alreadyInstalling
        case videoWorkInProgress
        case attempted
    }

    private let tiptoe: Tiptoe
    private let videoIsIdle: @MainActor @Sendable () -> Bool
    private var checkInFlight: Task<Void, Never>?
    private var manualRequested = false
    private var manualReserved = false
    private var installingVersion: String?

    var autoInstall = false {
        didSet { videoWorkChanged() }
    }

    var isReplacingApp: Bool {
        // Tiptoe sets this notice at handoff and clears it after a failed install rolls back.
        manualReserved || installingVersion.map { tiptoe.justUpdatedTo == $0 } == true
    }

    init(tiptoe: Tiptoe, videoIsIdle: @escaping @MainActor @Sendable () -> Bool) {
        self.tiptoe = tiptoe
        self.videoIsIdle = videoIsIdle
        tiptoe.stop()
        tiptoe.gate("a video optimization is running") { await videoIsIdle() }
        tiptoe.onWillInstall = { [weak self] pending in
            self?.installingVersion = pending.version
        }
    }

    func check(_ operation: @escaping @MainActor () async -> Void) async {
        if let checkInFlight {
            await checkInFlight.value
            return
        }
        guard !manualRequested, !isReplacingApp else { return }
        let task = Task { await operation() }
        checkInFlight = task
        videoWorkChanged()
        await task.value
        checkInFlight = nil
        videoWorkChanged()
    }

    func install(_ operation: @MainActor () async -> Void) async -> ManualResult {
        guard !manualRequested, !isReplacingApp else { return .alreadyInstalling }
        guard videoIsIdle() else { return .videoWorkInProgress }
        manualRequested = true
        videoWorkChanged()
        defer {
            manualReserved = false
            manualRequested = false
            videoWorkChanged()
        }
        await checkInFlight?.value
        guard videoIsIdle() else { return .videoWorkInProgress }
        // TiptoeGitHub combines preparation and install, so reserve the whole explicit call.
        manualReserved = true
        await operation()
        return .attempted
    }

    /// Video work enters and exits on the main actor, synchronously with this watcher change.
    func videoWorkChanged() {
        // Stopping Tiptoe can cancel its polling task, which may be performing the swap.
        guard !isReplacingApp else { return }
        if autoInstall, !manualRequested, checkInFlight == nil, videoIsIdle() {
            tiptoe.start()
        } else {
            tiptoe.stop()
        }
    }
}
