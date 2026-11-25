import AppKit
import Digoxin
import Foundation
import os

extension UsageCounting {
    static let shared = UsageCounting(
        stateURL: supportFolder.appending(path: "Reporting.json"),
        initialState: { build.initialState { UserDefaults.standard.string(forKey: legacyConsentKey) } },
        retireLegacy: build == .release ? { UserDefaults.standard.removeObject(forKey: legacyConsentKey) } : nil,
        legacyStore: build == .release ? LegacyStatisticsStore(
            old: supportFolder.appending(path: "Digoxin", directoryHint: .isDirectory),
            new: storageFolder(for: .statistics).appending(path: "Digoxin", directoryHint: .isDirectory),
        ) : nil,
        makeClient: makeClient,
        hasStrandedData: { stream, status in
            ReportingBuild.hasStrandedData(in: storageFolder(for: stream), deletionPending: status == .deletionPending)
        },
        crashApp: crashReportsApp,
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

    private nonisolated static let legacyConsentKey = "usageCounting"
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

    private nonisolated static func storageFolder(for stream: ReportingStream) -> URL {
        switch stream {
        case .statistics: build.statisticsFolder(in: supportFolder)
        case .legacyStatistics: supportFolder
        case .previousCrashes: supportFolder.appending(path: "CrashReports", directoryHint: .isDirectory)
        case .crashes: supportFolder.appending(path: crashReportsApp, directoryHint: .isDirectory)
        }
    }

    private static func makeClient(for stream: ReportingStream) -> any ReportingClient {
        Digoxin(configuration: .init(
            app: stream == .crashes ? crashReportsApp : statisticsApp,
            baseURL: baseURL, storageDirectory: storageFolder(for: stream),
            propertiesProvider: { await stream == .statistics ? libraryProperties() : [:] },
            log: { logger.info("\($0, privacy: .private)") },
        ))
    }

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
            let reader = Digoxin(configuration: .init(
                app: statisticsApp, baseURL: baseURL, storageDirectory: supportFolder.appending(path: "ActiveCount"),
            ))
            return try? await reader.activeCount().active
        }
    }
}
