import Foundation

nonisolated enum DebugLogging {
    static let changedNotification = "glass.kagerou.phosphene.verboseLoggingChanged"

    static func isEnabled(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("VERBOSE_LOG").path)
    }

    static func setEnabled(_ enabled: Bool, in directory: URL) throws {
        let marker = directory.appendingPathComponent("VERBOSE_LOG")
        if enabled {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try Data().write(to: marker, options: .withoutOverwriting)
            } catch CocoaError.fileWriteFileExists {
                // A marker created from the command line enables the same setting.
            }
        } else if unsafe unlink(marker.path) != 0, errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(changedNotification as CFString), nil, nil, true)
    }
}
