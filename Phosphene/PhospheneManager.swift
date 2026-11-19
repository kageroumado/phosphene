import AVFoundation
import os
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class PhospheneManager {
    /// Singleton reference for URL scheme handling from AppDelegate.
    private(set) weak static var shared: PhospheneManager?

    // MARK: - Optimization State

    private(set) var optimizationProgress: Double = 0
    private(set) var optimizingEntryID: String?
    private(set) var isCancellingOptimization = false
    var showOptimizationAlert = false
    var optimizationAlertMessage = ""
    @ObservationIgnored private var optimizationJobID: UUID?
    @ObservationIgnored private var optimizationTask: Task<Void, Never>?

    var isOptimizing: Bool {
        optimizingEntryID != nil
    }

    // MARK: - Preferences

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            guard !isUpdatingLaunchAtLogin else { return }
            isUpdatingLaunchAtLogin = true
            let desired = launchAtLogin
            Task {
                defer { isUpdatingLaunchAtLogin = false }
                do {
                    try await LaunchAtLoginService.shared.setEnabled(desired)
                } catch {
                    Log.general.error("Launch at login update failed: \(error.localizedDescription)")
                    launchAtLogin = !desired
                }
            }
        }
    }

    var autoUpdate: Bool {
        didSet {
            guard autoUpdate != oldValue else { return }
            UserDefaults.standard.set(autoUpdate, forKey: Keys.autoUpdate)
            SilentUpdates.shared.setAutoInstall(autoUpdate)
        }
    }

    // MARK: - Services

    let prefsService = WallpaperPrefsService.shared
    let occlusionMonitor = OcclusionMonitor()
    /// Wallpaper Engine downloads and the queue that turns them into videos.
    let workshop = WorkshopLibrary()

    // MARK: - Private

    @ObservationIgnored private var isUpdatingLaunchAtLogin = false

    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let autoUpdate = "autoInstallUpdates"
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.launchAtLogin: true,
            Keys.autoUpdate: true,
        ])
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.autoUpdate = defaults.bool(forKey: Keys.autoUpdate)

        Self.shared = self
        syncLaunchAtLogin()

        // Clear legacy bookmark if present
        defaults.removeObject(forKey: "videoBookmarkKey")

        // Clear the retired resume-on-launch preference: the extension resumes on
        // its own, so the setting was never read.
        defaults.removeObject(forKey: "resumeLastWallpaper")

        if !defaults.bool(forKey: "didPublishNonPurgeableChoices") {
            VideoDeploymentService.notifyExtensionLibraryChanged()
            defaults.set(true, forKey: "didPublishNonPurgeableChoices")
        }

        // Migrate entries imported before metadata probing was added
        migrateEntryMetadata()

        // Always on: the fullscreen-app pause needs it regardless of the
        // "Pause When Hidden" setting, which only gates the occlusion tier.
        occlusionMonitor.startMonitoring()

        SilentUpdates.shared.start(autoInstall: autoUpdate)
        UsageCounting.start()
    }

    // MARK: - Library Actions

    func openVideoChooser() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                await importVideo(url)
            }
        }
    }

    /// Import a video into the extension library.
    /// Does NOT set it as the active wallpaper — the user selects in System Settings.
    func importVideo(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let name = url.deletingPathExtension().lastPathComponent
        await VideoDeploymentService.deployVideo(url: url, name: name) { error in
            self.optimizationAlertMessage = error.localizedDescription
            self.showOptimizationAlert = true
        }
    }

    func optimize(_ target: VideoOptimizationTarget, preset: OptimizationPreset, convertToSDR: Bool) {
        guard !isOptimizing, target.tiers.isEmpty else { return }
        if let error = target.eligibilityError {
            optimizationAlertMessage = error.localizedDescription
            showOptimizationAlert = true
            return
        }

        let entryID = target.id
        let jobID = UUID()
        optimizationJobID = jobID
        optimizationProgress = 0
        optimizingEntryID = entryID

        optimizationTask = Task {
            defer {
                assert(optimizationJobID == jobID && optimizingEntryID == entryID)
                optimizationTask = nil
                optimizationJobID = nil
                optimizingEntryID = nil
                isCancellingOptimization = false
            }
            do {
                try Task.checkCancellation()
                try await target.optimize(preset: preset, convertToSDR: convertToSDR && target.entry.sourceIsHDR == true) { progress in
                    guard self.optimizationJobID == jobID, !self.isCancellingOptimization else { return }
                    self.optimizationProgress = max(self.optimizationProgress, progress)
                }
            } catch {
                guard !Task.isCancelled else { return }
                optimizationAlertMessage = error.localizedDescription
                showOptimizationAlert = true
            }
        }
    }

    func removeVariants(for target: VideoOptimizationTarget) {
        guard optimizingEntryID != target.id else { return }
        do {
            if let pair = target.pair?.saved {
                try VideoDeploymentService.removePairVariants(pair)
            } else {
                try VideoDeploymentService.removeVariants(entryID: target.id)
            }
        } catch {
            optimizationAlertMessage = error.localizedDescription
            showOptimizationAlert = true
        }
    }

    func cancelOptimization(entryID: String) {
        guard optimizingEntryID == entryID, let optimizationTask, !isCancellingOptimization else { return }
        isCancellingOptimization = true
        optimizationTask.cancel()
    }

    // MARK: - Private

    private func migrateEntryMetadata() {
        _ = VideoDeploymentService.prettifyLegacyNames()
        let entries = VideoDeploymentService.listEntries()
        let needsProbing = entries.filter { $0.sourceIsHDR == nil || ($0.resolution == .zero && $0.fps == 0) }
        guard !needsProbing.isEmpty else { return }
        Task {
            var changed = false
            for entry in needsProbing {
                if await VideoDeploymentService.probeAndUpdateMetadata(for: entry) {
                    changed = true
                }
            }
            if changed {
                VideoDeploymentService.notifyExtensionLibraryChanged()
            }
        }
    }

    private func syncLaunchAtLogin() {
        Task {
            let service = LaunchAtLoginService.shared
            service.checkStatus()
            if service.isEnabled != launchAtLogin {
                isUpdatingLaunchAtLogin = true
                launchAtLogin = service.isEnabled
                isUpdatingLaunchAtLogin = false
            }
            if launchAtLogin, !service.isEnabled {
                try? await service.setEnabled(true)
            }
        }
    }
}
