/// Serializes video job admission with the reservation to replace the app.
@MainActor
final class VideoWorkGate {
    static let shared = VideoWorkGate()

    private var jobs = 0
    private(set) var isReplacingApp = false
    var onWorkChanged: (() -> Void)?

    var canReplaceApp: Bool { jobs == 0 && !isReplacingApp }

    func beginWork() -> Bool {
        guard !isReplacingApp else { return false }
        jobs += 1
        onWorkChanged?()
        return true
    }

    func endWork() {
        jobs -= 1
        onWorkChanged?()
    }

    func beginReplacement() -> Bool {
        guard canReplaceApp else { return false }
        isReplacingApp = true
        return true
    }

    func endReplacement() {
        isReplacingApp = false
    }
}
