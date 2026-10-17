import AppKit
import Digoxin
import Foundation
import os

/// How many people use Phosphene, and Phosphene's own crashes, through Digoxin at the
/// tier the person chose (``tier``).
///
/// A check-in carries the versions, the chip family, the memory class, the language, the
/// count of days used in the last week, and the two properties in ``properties()``. It
/// names no video. The wallpaper extension runs inside the system's wallpaper process,
/// so its crashes are the system's reports, and only the app's own are sent.
nonisolated enum UsageCounting {
    static let app = "phosphene"

    /// Production for a release build. A Debug build reports to a Digoxin on this Mac, or
    /// to the one `PHOSPHENE_DIGOXIN_URL` names.
    static let baseURL: URL = {
        #if DEBUG
            ProcessInfo.processInfo.environment["PHOSPHENE_DIGOXIN_URL"].flatMap(URL.init(string:))
                ?? URL(string: "http://127.0.0.1:9130/api/digoxin")!
        #else
            URL(string: "https://kagerou.glass/api/digoxin")!
        #endif
    }()

    /// The app's own Application Support folder; Digoxin keeps its state in a `Digoxin`
    /// folder inside it.
    static let supportFolder = URL.applicationSupportDirectory
        .appending(path: "Phosphene", directoryHint: .isDirectory)

    /// The crash reports macOS writes for the app carry this process name.
    static let processName = "Phosphene"

    private static let logger = Logger(subsystem: "glass.kagerou.phosphene", category: "UsageCounting")

    static let client = Digoxin(configuration: .init(
        app: app,
        baseURL: baseURL,
        storageDirectory: supportFolder,
        propertiesProvider: { await properties() },
        log: { logger.info("\($0, privacy: .public)") },
    ))

    /// The heartbeat's app properties, each on the server's allowlist for Phosphene:
    /// whether the library holds at least one imported video, and how many displays are
    /// connected.
    private static func properties() async -> [String: TelemetryValue] {
        await MainActor.run {
            [
                "ownVideos": .bool(!VideoDeploymentService.listEntries().isEmpty),
                "displays": .int(NSScreen.screens.count),
            ]
        }
    }

    // MARK: - Lifecycle

    /// At launch: applies the stored tier, sends the reports of crashes since the last look,
    /// and counts the day.
    static func start() {
        Task.detached(name: "Usage counting at launch") {
            await client.setTier(tier ?? .off)
            await submitOwnCrashes()
            await client.recordUse()
        }
    }

    /// The popover opened: counts the day, and sends a crash that happened since launch.
    static func noteUse() {
        Task.detached(name: "Usage counting on use") {
            await submitOwnCrashes()
            await client.recordUse()
        }
    }

    /// The person's choice, from the question card or the popover's settings.
    static func choose(_ newTier: ConsentTier) {
        let previous = tier
        tier = newTier
        // Crashes before the choice are not the choice's to send.
        if newTier == .crashReports, previous != .crashReports {
            ownCrashesCheckedAt = Date()
        }
        logger.info("chose \(newTier.rawValue, privacy: .public)")
        Task.detached(name: "Apply the usage counting tier") {
            await client.setTier(newTier)
            if newTier != .off {
                await client.recordUse()
            }
        }
    }

    /// One report per crash of the app since the last look, at the crash-reports tier; the
    /// look moves forward at every tier, so turning reports on later sends nothing from
    /// before.
    private static func submitOwnCrashes() async {
        let now = Date()
        let since = ownCrashesCheckedAt
        ownCrashesCheckedAt = now
        guard tier == .crashReports, let since else { return }
        let bundleID = Bundle.main.bundleIdentifier
        let reports = DiagnosticReports.reports(forProcess: processName, after: since)
        for report in reports where OwnCrashReports.isOurs(report, bundleID: bundleID) {
            await client.submitCrashReport(files: [report])
        }
    }

    // MARK: - Stored choice

    /// The Digoxin tier the person chose; `nil` until they have been asked, which is what
    /// makes the question appear once, including after an update from a version that
    /// never asked.
    static var tier: ConsentTier? {
        get { UserDefaults.standard.string(forKey: tierKey).flatMap(ConsentTier.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: tierKey) }
    }

    static let tierKey = "usageCounting"

    /// When the app's crash reports were last looked for: reports written after it are the
    /// ones not yet sent.
    private static var ownCrashesCheckedAt: Date? {
        get { UserDefaults.standard.object(forKey: "ownCrashesCheckedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "ownCrashesCheckedAt") }
    }
}

// MARK: - Own crash reports

/// Which of the crash reports macOS wrote under the app's process name are the app's.
///
/// macOS writes `procPath` with the home folder masked (`/Users/USER/…`), so the path
/// cannot tell the app from another process of the same name. The header line can: a
/// crash names the bundle identifier of the app that crashed.
nonisolated enum OwnCrashReports {
    /// `bug_type` of a crash. A hang or a spin is written under other types.
    static let crashBugType = "309"

    /// Whether the `.ips` file at `url` is a crash of the app whose identifier is `bundleID`.
    static func isOurs(_ url: URL, bundleID: String?) -> Bool {
        guard let bundleID, let data = try? Data(contentsOf: url) else { return false }
        return isCrash(data, of: bundleID)
    }

    /// Whether an `.ips` file (a JSON header line, then the JSON body) is a crash of the app
    /// whose identifier is `bundleID`.
    static func isCrash(_ ips: Data, of bundleID: String) -> Bool {
        let line = ips.prefix { $0 != UInt8(ascii: "\n") }
        guard let header = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              header["bug_type"] as? String == crashBugType
        else { return false }
        return header["bundleID"] as? String == bundleID
    }
}

// MARK: - Yesterday's count

extension UsageCounting {
    /// How many Macs counted themselves in yesterday, from the service's public summary;
    /// `nil` while the service has not answered, or answered with anything but a count.
    static func activeMacs() async -> Int? {
        await activeCount.value()
    }

    private static let activeCount = ActiveCount()

    /// Yesterday's count from the service's public summary, kept for the process once it has
    /// arrived; a failed ask is tried again on the next ask.
    private actor ActiveCount {
        private var cached: Int?
        private var inFlight: Task<Int?, Never>?

        func value() async -> Int? {
            if let cached {
                return cached
            }
            if let inFlight {
                return await inFlight.value
            }
            let task = Task<Int?, Never> { await Self.fetch() }
            inFlight = task
            let result = await task.value
            inFlight = nil
            cached = result
            return result
        }

        private static func fetch() async -> Int? {
            try? await client.activeCount().active
        }
    }
}
