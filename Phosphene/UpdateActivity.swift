import Tiptoe

/// Coordinates AppUpdater preparation and Tiptoe installation with video work.
@MainActor
final class UpdateActivity {
    struct Candidate {
        let version: String
        let prepare: @MainActor () async throws -> Download
    }

    struct Download {
        let install: @MainActor () async throws -> Void
        let discard: @MainActor () async -> Void
    }

    enum ManualResult: Equatable {
        case alreadyInstalling
        case videoWorkInProgress
        case noMatchingDownload
        case attempted
    }

    private enum InstallError: Error { case unavailable }

    private let tiptoe: Tiptoe
    private let videoIsIdle: @MainActor @Sendable () -> Bool
    private var checkInFlight: Task<Void, Never>?
    private var manualVersion: String?
    private var staged: (version: String, download: Download)?
    private(set) var isReplacingApp = false

    var autoInstall = false {
        didSet { videoWorkChanged() }
    }

    var pendingVersion: String? {
        staged?.version
    }

    init(tiptoe: Tiptoe, videoIsIdle: @escaping @MainActor @Sendable () -> Bool) {
        self.tiptoe = tiptoe
        self.videoIsIdle = videoIsIdle
        tiptoe.stop()
        tiptoe.gate("a video optimization is running") { await videoIsIdle() }
    }

    func check(_ operation: @escaping @MainActor () async -> Void) async {
        if let checkInFlight {
            await checkInFlight.value
            return
        }
        guard manualVersion == nil, !isReplacingApp else { return }
        let task = Task { await operation() }
        checkInFlight = task
        videoWorkChanged()
        await task.value
        checkInFlight = nil
        videoWorkChanged()
    }

    /// Preparation and installation run inside the serialized check or manual request.
    func prepare(_ candidate: Candidate) async throws {
        guard pendingVersion != candidate.version else { return }
        let previous = staged
        staged = nil
        // Preparing an AppUpdater download can clean up another promoted image.
        await previous?.download.discard()
        staged = try await (candidate.version, candidate.prepare())
        holdPrepared(version: candidate.version)
    }

    func install(version: String, findCandidate: @MainActor () async throws -> Candidate?) async throws -> ManualResult {
        guard manualVersion == nil, !isReplacingApp else { return .alreadyInstalling }
        guard videoIsIdle() else { return .videoWorkInProgress }
        manualVersion = version
        videoWorkChanged()
        defer {
            manualVersion = nil
            videoWorkChanged()
        }
        await checkInFlight?.value
        guard videoIsIdle() else { return .videoWorkInProgress }

        if pendingVersion != version {
            guard let candidate = try await findCandidate(), candidate.version == version else {
                return .noMatchingDownload
            }
            try await prepare(candidate)
        }
        guard videoIsIdle() else { return .videoWorkInProgress }
        holdPrepared(version: version)
        await tiptoe.installNow().value
        return pendingVersion == version ? .videoWorkInProgress : .attempted
    }

    private func holdPrepared(version: String) {
        guard tiptoe.pending?.version != version else { return }
        tiptoe.hold(version: version, retryable: false) { [weak self] in
            guard let self else { throw InstallError.unavailable }
            try await swap(version: version)
        }
    }

    private func swap(version: String) async throws {
        guard let staged, staged.version == version, !isReplacingApp,
              manualVersion.map({ $0 == version }) ?? autoInstall,
              videoIsIdle() else { throw InstallError.unavailable }
        isReplacingApp = true
        self.staged = nil
        do {
            try await staged.download.install()
        } catch {
            isReplacingApp = false
            videoWorkChanged()
            throw error
        }
        // AppUpdater schedules termination after a successful swap. The old process remains reserved.
    }

    /// Video work enters and exits on the main actor, synchronously with this watcher change.
    func videoWorkChanged() {
        // Stopping Tiptoe can cancel its polling task, which may be performing the swap.
        guard !isReplacingApp else { return }
        if autoInstall, manualVersion == nil, checkInFlight == nil, let version = pendingVersion, videoIsIdle() {
            holdPrepared(version: version)
            tiptoe.start()
        } else {
            tiptoe.stop()
        }
    }
}
