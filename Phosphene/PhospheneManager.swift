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

    private(set) var isOptimizing = false
    private(set) var optimizationProgress: Double = 0
    private(set) var optimizationTierLabel = ""
    private(set) var optimizingEntryID: String?
    var showOptimizationAlert = false
    var optimizationAlertMessage = ""
    @ObservationIgnored private var optimizationTask: Task<Void, Never>?

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
    let updateCheck = UpdateCheckService()

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

        // Migrate entries imported before metadata probing was added
        migrateEntryMetadata()

        if prefsService.pauseWhenOccluded {
            occlusionMonitor.startMonitoring()
        }

        Task { await updateCheck.checkIfDue() }
        SilentUpdates.shared.start(autoInstall: autoUpdate)
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
        guard url.startAccessingSecurityScopedResource() else {
            Log.general.error("Failed to access security-scoped resource for \(url.lastPathComponent)")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let name = url.deletingPathExtension().lastPathComponent
        await VideoDeploymentService.deployVideo(url: url, name: name)
    }

    func removeVideo(entryID: String) {
        VideoDeploymentService.removeVideo(entryID: entryID)
    }

    func optimizeVideo(entryID: String, preset: OptimizationPreset) {
        guard !isOptimizing else { return }
        isOptimizing = true
        optimizingEntryID = entryID
        optimizationProgress = 0

        let entry = VideoDeploymentService.listEntries().first(where: { $0.id == entryID })
        guard let entry else {
            isOptimizing = false
            optimizingEntryID = nil
            return
        }

        let sourceURL = VideoDeploymentService.videoURL(for: entry)
        let target = preset.targetResolution(source: entry.resolution)

        optimizationTask = Task.detached {
            do {
                let variants = try await VideoOptimizationService.createVariants(
                    sourceURL: sourceURL,
                    targetResolution: target,
                    progress: { @MainActor in self.optimizationProgress = $0 },
                )
                await MainActor.run {
                    VideoDeploymentService.deployVariants(entryID: entryID, variants: variants)
                }
                for (url, _) in variants {
                    try? FileManager.default.removeItem(at: url)
                }
            } catch is CancellationError {
                // user cancelled
            } catch {
                await MainActor.run {
                    self.optimizationAlertMessage = error.localizedDescription
                    self.showOptimizationAlert = true
                }
            }

            await MainActor.run {
                self.isOptimizing = false
                self.optimizingEntryID = nil
            }
        }
    }

    func removeVariants(entryID: String) {
        VideoDeploymentService.removeVariants(entryID: entryID)
    }

    func cancelOptimization() {
        optimizationTask?.cancel()
        optimizationTask = nil
        isOptimizing = false
        optimizingEntryID = nil
    }

    // MARK: - Private

    private func migrateEntryMetadata() {
        _ = VideoDeploymentService.prettifyLegacyNames()
        let entries = VideoDeploymentService.listEntries()
        let needsProbing = entries.filter { $0.resolution == .zero && $0.fps == 0 }
        guard !needsProbing.isEmpty else { return }
        Task {
            for entry in needsProbing {
                await VideoDeploymentService.probeAndUpdateMetadata(for: entry.id)
            }
            NotificationCenter.default.post(name: VideoDeploymentService.libraryChangedNotification, object: nil)
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
