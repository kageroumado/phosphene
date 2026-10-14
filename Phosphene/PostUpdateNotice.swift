/// A persisted "updated to X" notice describes the running app only while X is the version
/// that is running.
enum PostUpdateNotice {
    /// Returns the recorded version when it matches the running bundle, so the host can show
    /// it until the user acknowledges it. A notice that outlived its version (Homebrew, a
    /// dragged-in DMG or a downgrade replaced the app without the updater) is acknowledged
    /// through `acknowledge` instead, so it stays cleared on later launches.
    static func reconcile(
        recordedVersion: String?,
        runningVersion: String?,
        acknowledge: () -> Void,
    ) -> String? {
        guard let recordedVersion else { return nil }
        guard !recordedVersion.isEmpty, recordedVersion == runningVersion else {
            acknowledge()
            return nil
        }
        return recordedVersion
    }
}
