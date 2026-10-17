import Foundation
import Synchronization

/// A bake runs in a helper copy of Phosphene, launched with `--bake <request>`: a
/// shader that hangs Apple's GLSL compiler or the GPU then ends that process, and
/// the menu bar app reports a failed video. The helper writes one JSON
/// ``WEBakeMessage`` per line to its standard output.
nonisolated struct WEBakeRequest: Codable {
    var folder: URL
    var assets: URL?
    var settings: WEBakeSettings
    var output: URL
}

nonisolated enum WEBakeMessage: Codable {
    case progress(fraction: Double, phase: String)
    case finished(WEBakeResult)
    case failed(String)
}

/// The helper side: runs in `main.swift` before the app starts.
nonisolated enum WEBakeHelper {
    static let argument = "--bake"
    private static let terminated = Atomic(false)

    /// Bake the request at `path` and return the process's exit status.
    static func run(requestPath path: String) -> Int32 {
        // The app cancels by sending SIGTERM; the render loop sees it between frames,
        // so the scratch folder is still removed.
        signal(SIGTERM) { _ in WEBakeHelper.terminated.store(true, ordering: .relaxed) }
        do {
            let request = try JSONDecoder().decode(WEBakeRequest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let result = try WEBaker.bake(
                folder: request.folder, assets: request.assets, settings: request.settings, output: request.output,
                progress: { emit(.progress(fraction: $0, phase: $1)) },
                // A parent that has gone leaves the helper to launchd (pid 1).
                isCancelled: { terminated.load(ordering: .relaxed) || getppid() == 1 },
            )
            emit(.finished(result))
            return 0
        } catch {
            emit(.failed(error.localizedDescription))
            return 1
        }
    }

    private static func emit(_ message: WEBakeMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

/// The app side: one helper process per bake.
@MainActor
final class WEBakeHost {
    private let request: WEBakeRequest
    private let process = Process()
    private var pending = Data()
    private var outcome: Result<WEBakeResult, any Error>?
    private var wasCancelled = false

    init(request: WEBakeRequest) {
        self.request = request
    }

    /// Run the bake, reporting progress on the main actor, and return its result.
    func run(progress: @escaping @MainActor (Double, String) -> Void) async throws -> WEBakeResult {
        let requestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-engine-request-\(UUID().uuidString).json")
        try JSONEncoder().encode(request).write(to: requestURL)
        defer { try? FileManager.default.removeItem(at: requestURL) }

        let pipe = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = [WEBakeHelper.argument, requestURL.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        process.qualityOfService = .userInitiated
        return try await withCheckedThrowingContinuation { continuation in
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.consume(data, progress: progress) }
                }
            }
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                pipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.consume(pipe.fileHandleForReading.readDataToEndOfFile(), progress: progress)
                        continuation.resume(with: self.outcome ?? .failure(self.exitError(status)))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        wasCancelled = true
        if process.isRunning {
            process.terminate()
        }
    }

    private func consume(_ data: Data, progress: @MainActor (Double, String) -> Void) {
        pending.append(data)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex ..< newline]
            pending = pending[(newline + 1)...]
            guard let message = try? JSONDecoder().decode(WEBakeMessage.self, from: line) else { continue }
            switch message {
            case let .progress(fraction, phase): progress(fraction, phase)
            case let .finished(result): outcome = .success(result)
            case let .failed(reason): outcome = .failure(wasCancelled ? CancellationError() : WEError.malformed(reason))
            }
        }
    }

    private func exitError(_ status: Int32) -> any Error {
        if wasCancelled {
            return CancellationError()
        }
        return WEError.unsupported("the render stopped (exit \(status)); a shader may have hung the GPU")
    }
}
