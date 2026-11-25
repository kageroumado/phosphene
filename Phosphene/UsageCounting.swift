import AppKit
import Digoxin
import Foundation
import Observation
import os

/// How many people use Phosphene, and Phosphene's own crashes, through Digoxin.
/// The wallpaper extension runs inside the system's wallpaper process, so only
/// the app's own crashes are sent.
@MainActor @Observable
final class UsageCounting {
    static let shared = UsageCounting()
    private static let consentKey = "usageCounting"
    private static let scanDateKey = "ownCrashesCheckedAt"

    private var storedConsent = ReportingConsent(storedValue: UserDefaults.standard.string(forKey: consentKey))
    var shouldAsk: Bool {
        storedConsent == nil
    }

    var consent: ReportingConsent {
        get { storedConsent ?? ReportingConsent() }
        set {
            guard storedConsent != newValue else { return }
            let wasReportingCrashes = consent.crashReports
            storedConsent = newValue
            UserDefaults.standard.set(newValue.storedValue, forKey: Self.consentKey)
            Self.logger.info("chose \(newValue.storedValue, privacy: .public)")
            if wasReportingCrashes != newValue.crashReports {
                crashTask?.cancel()
                UserDefaults.standard.set(Date.now, forKey: Self.scanDateKey)
                checkCrashReports()
            }
            updateStatistics()
        }
    }

    private(set) var statisticsStatus: DigoxinStatus = .off
    private(set) var crashStatus: DigoxinStatus = .off
    @ObservationIgnored private var crashTask: Task<Void, Never>?
    @ObservationIgnored private var statisticsTask: Task<Void, Never>?

    private nonisolated static let baseURL: URL = {
        #if DEBUG
            ProcessInfo.processInfo.environment["PHOSPHENE_DIGOXIN_URL"].flatMap(URL.init(string:))
                ?? URL(string: "http://127.0.0.1:9130/api/digoxin")!
        #else
            URL(string: "https://kagerou.glass/api/digoxin")!
        #endif
    }()
    private nonisolated static let supportFolder: URL = {
        let folder = URL.applicationSupportDirectory.appending(path: "Phosphene", directoryHint: .isDirectory)
        #if DEBUG
            // The development endpoint must never drain a release build's queues.
            return folder.appending(path: "Debug", directoryHint: .isDirectory)
        #else
            return folder
        #endif
    }()

    private nonisolated static let logger = Logger(subsystem: "glass.kagerou.phosphene", category: "UsageCounting")

    /// Separate queues let either permission be revoked while the other is still in use.
    private nonisolated static let statistics = Digoxin(configuration: .init(
        app: "phosphene", baseURL: baseURL, storageDirectory: supportFolder,
        propertiesProvider: { await libraryProperties() },
        log: { logger.info("\($0, privacy: .public)") },
    ))
    private nonisolated static let crashes = Digoxin(configuration: .init(
        app: "phosphene", baseURL: baseURL,
        storageDirectory: supportFolder.appending(path: "CrashReports", directoryHint: .isDirectory),
        log: { logger.info("\($0, privacy: .public)") },
    ))

    private static func libraryProperties() -> [String: TelemetryValue] {
        [
            "ownVideos": .bool(!VideoDeploymentService.listEntries().isEmpty),
            "displays": .int(NSScreen.screens.count),
        ]
    }

    func noteUse() {
        updateStatistics()
        if crashTask == nil {
            checkCrashReports()
        }
    }

    private func updateStatistics() {
        statisticsTask?.cancel()
        statisticsTask = Task {
            let client = Self.statistics
            let oldTier = await client.tier
            guard !Task.isCancelled else { return }
            // A legacy combined queue can finish sending its reports while both grants remain.
            let enabledTier: ConsentTier = oldTier == .crashReports && consent.crashReports ? .crashReports : .counting
            await client.setTier(consent.usageStatistics ? enabledTier : .off)
            guard !Task.isCancelled else { return }
            if consent.usageStatistics {
                await client.recordUse()
            } else {
                await client.flush()
            }
            let status = await client.status
            guard !Task.isCancelled else { return }
            statisticsStatus = status
        }
    }

    private func checkCrashReports() {
        crashTask = Task {
            guard !Task.isCancelled else { return }
            let client = Self.crashes
            await client.setTier(consent.crashReports ? .crashReports : .off)
            guard !Task.isCancelled else { return }
            if consent.crashReports {
                let since = UserDefaults.standard.object(forKey: Self.scanDateKey) as? Date
                let scanDate = Date.now
                if let since {
                    let reports = await OwnCrashReports.reports(after: since)
                    for report in reports {
                        guard !Task.isCancelled else { return }
                        await client.submitCrashReport(files: [report])
                    }
                }
                guard !Task.isCancelled else { return }
                UserDefaults.standard.set(scanDate, forKey: Self.scanDateKey)
            }
            // Retry pending reports and deletions without recording a day of use.
            await client.flush()
            let status = await client.status
            guard !Task.isCancelled else { return }
            crashStatus = status
            crashTask = nil
        }
    }
}

// MARK: - Own crash reports

/// Which of the crash reports macOS wrote under the app's process name are the app's.
///
/// macOS writes `procPath` with the home folder masked (`/Users/USER/…`), so the path
/// cannot tell the app from another process of the same name. The header line can: a
/// crash names the bundle identifier of the app that crashed.
nonisolated enum OwnCrashReports {
    @concurrent
    static func reports(after date: Date) async -> [URL] {
        let bundleID = Bundle.main.bundleIdentifier
        return DiagnosticReports.reports(forProcess: "Phosphene", after: date)
            .filter { isOurs($0, bundleID: bundleID) }
    }

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
    func activeMacs() async -> Int? {
        await Self.activeCount.value()
    }

    private nonisolated static let activeCount = ActiveCount()

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
            try? await statistics.activeCount().active
        }
    }
}
