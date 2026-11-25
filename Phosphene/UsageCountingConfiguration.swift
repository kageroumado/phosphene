import AppKit
import Digoxin
import Foundation
import os

extension UsageCounting {
    static let shared = UsageCounting(
        stateURL: supportFolder.appending(path: "Reporting.json"),
        initialState: { build.initialState { UserDefaults.standard.string(forKey: "usageCounting") } },
        statistics: statistics,
        previousCrashes: previousCrashes,
        crashDestination: (crashReportsApp, crashes),
        currentCrashSlice: build.crashSlice,
        findReports: build.reports,
    )

    private nonisolated static let build: ReportingBuild = {
        #if DEBUG
            .debug
        #else
            .release
        #endif
    }()

    private nonisolated static let statisticsApp = "phosphene"
    private nonisolated static let crashReportsApp = "phosphene-crashes"

    private nonisolated static let baseURL: URL = {
        #if DEBUG
            ProcessInfo.processInfo.environment["PHOSPHENE_DIGOXIN_URL"].flatMap(URL.init(string:))
                ?? URL(string: "http://127.0.0.1:9130/api/digoxin")!
        #else
            URL(string: "https://kagerou.glass/api/digoxin")!
        #endif
    }()
    private nonisolated static let supportFolder = build.supportFolder(
        in: URL.applicationSupportDirectory.appending(path: "Phosphene", directoryHint: .isDirectory),
    )

    private nonisolated static let logger = Logger(subsystem: "glass.kagerou.phosphene", category: "UsageCounting")

    private nonisolated static let statistics = Digoxin(configuration: .init(
        app: statisticsApp, baseURL: baseURL, storageDirectory: supportFolder,
        propertiesProvider: { await libraryProperties() },
        log: { logger.info("\($0, privacy: .private)") },
    ))
    private nonisolated static let previousCrashes = Digoxin(configuration: .init(
        app: statisticsApp, baseURL: baseURL,
        storageDirectory: supportFolder.appending(path: "CrashReports", directoryHint: .isDirectory),
        log: { logger.info("\($0, privacy: .private)") },
    ))

    private nonisolated static let crashes = Digoxin(configuration: .init(
        app: crashReportsApp, baseURL: baseURL,
        storageDirectory: supportFolder.appending(path: crashReportsApp, directoryHint: .isDirectory),
        log: { logger.info("\($0, privacy: .private)") },
    ))

    private static func libraryProperties() -> [String: TelemetryValue] {
        [
            "ownVideos": .bool(!VideoDeploymentService.listEntries().isEmpty),
            "displays": .int(NSScreen.screens.count),
        ]
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
