import AppKit
import Digoxin
import Foundation
import os

extension UsageCounting {
    static let shared = makeShared()

    @MainActor
    private static func makeShared() -> UsageCounting {
        UsageCounting(
            stateURL: supportFolder.appending(path: "UsageCounting.json"),
            initialState: {
                build.initialState(
                    preferenceForKey: { UserDefaults.standard.string(forKey: $0) },
                    upstreamCutoff: UserDefaults.standard.object(forKey: "ownCrashesCheckedAt") as? Date,
                    previewURL: supportFolder.appending(path: "Reporting.json"),
                )
            },
            savePreference: { UserDefaults.standard.set($0.rawValue, forKey: build.preferenceKey) },
            makeClient: { makeClient() },
            hasStrandedData: { status in
                ReportingBuild.hasStrandedData(in: supportFolder, deletionPending: status == .deletionPending)
            },
            currentCrashSlice: build == .release ? OwnCrashReports.currentSliceUUID() : nil,
            findReports: findReports,
        )
    }

    private nonisolated static let build: ReportingBuild = {
        #if DEBUG
            .debug
        #else
            .release
        #endif
    }()

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

    private static func makeClient() -> Digoxin {
        Digoxin(configuration: .init(
            app: "phosphene",
            baseURL: baseURL, storageDirectory: supportFolder,
            propertiesProvider: { await libraryProperties() },
            log: { logger.info("\($0, privacy: .private)") },
        ))
    }

    @concurrent
    private nonisolated static func findReports(
        after date: Date, through cutoff: Date, releaseSlices: Set<UUID>,
    ) async -> [OwnCrashReports.Report] {
        // Debug and Release share a bundle identifier in macOS diagnostic reports.
        guard build == .release else { return [] }
        return await OwnCrashReports.reports(after: date, through: cutoff, releaseSlices: releaseSlices)
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
        await Self.activeCount.value { [self] in client ?? Self.makeClient() }
    }

    private nonisolated static let activeCount = ActiveCount()

    /// Yesterday's count from the service's public summary, kept for the process once it has
    /// arrived; a failed ask is tried again on the next ask.
    private actor ActiveCount {
        private var cached: Int?
        private var inFlight: Task<Int?, Never>?

        func value(client: @escaping @MainActor @Sendable () -> any ReportingClient) async -> Int? {
            if let cached {
                return cached
            }
            if let inFlight {
                return await inFlight.value
            }
            let task = Task<Int?, Never> { try? await client().activeCount().active }
            inFlight = task
            let result = await task.value
            inFlight = nil
            cached = result
            return result
        }
    }
}
