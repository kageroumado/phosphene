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
    private(set) var optimizingEntryID: String?
    /// Whether the running operation re-encodes the entry's original file as HEVC.
    private(set) var isConverting = false
    /// A failed optimization or conversion, shown as an alert by the library window.
    var showOptimizationAlert = false
    private(set) var optimizationAlertTitle = ""
    private(set) var optimizationAlertMessage = ""
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
    /// Wallpaper Engine downloads and the queue that turns them into videos.
    let workshop = WorkshopLibrary()
    /// The library window's state. One window shows the library, so its selection and
    /// section outlive the window.
    @ObservationIgnored private(set) lazy var library = LibraryStore(manager: self)

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

        // Always on: the fullscreen-app pause needs it regardless of the
        // "Pause When Hidden" setting, which only gates the occlusion tier.
        occlusionMonitor.startMonitoring()

        SilentUpdates.shared.start(autoInstall: autoUpdate)
        UsageCounting.shared.noteUse()
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
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn’t Import Video")
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    private func reportLibraryError(_ error: any Error, title: String) {
        optimizationAlertTitle = title
        optimizationAlertMessage = error.localizedDescription
        showOptimizationAlert = true
    }

    func optimize(_ target: VideoOptimizationTarget, preset: OptimizationPreset, convertToSDR: Bool) {
        guard !isOptimizing, target.tiers.isEmpty else { return }
        let title = String(localized: "Couldn't optimize the video.")
        if let error = target.eligibilityError {
            reportLibraryError(error, title: title)
            return
        }
        guard VideoWorkGate.shared.beginWork() else { return }
        isOptimizing = true
        optimizingEntryID = target.id
        optimizationProgress = 0
        optimizationTask = Task {
            defer { finishVideoWork() }
            do {
                try Task.checkCancellation()
                try await target.optimize(
                    preset: preset, convertToSDR: convertToSDR,
                ) { progress in
                    self.optimizationProgress = progress
                }
            } catch {
                guard !Task.isCancelled else { return }
                reportLibraryError(error, title: title)
            }
        }
    }

    /// Re-encode an entry's video as HEVC in place, keeping the entry and the wallpaper
    /// selections that use it. Shares the optimization state, so one conversion or
    /// optimization runs at a time and app updates wait for it.
    func convertToHEVC(entryID: String) {
        guard !isOptimizing,
              let entry = VideoDeploymentService.listEntries().first(where: { $0.id == entryID }),
              VideoWorkGate.shared.beginWork()
        else { return }
        isOptimizing = true
        isConverting = true
        optimizingEntryID = entryID
        optimizationProgress = 0

        optimizationTask = Task(name: "Convert to HEVC") {
            defer { finishVideoWork() }
            do {
                try Task.checkCancellation()
                try await VideoDeploymentService.convertToHEVC(entry: entry) { self.optimizationProgress = $0 }
            } catch {
                guard !Task.isCancelled else { return }
                Log.video.error("HEVC conversion of \(entryID) failed: \(error.localizedDescription)")
                self.optimizationAlertTitle = String(localized: "Couldn't convert the video to HEVC.")
                self.optimizationAlertMessage = error.localizedDescription
                self.showOptimizationAlert = true
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
            reportLibraryError(error, title: String(localized: "Couldn’t Remove Optimized Versions"))
        }
    }

    func cancelOptimization() {
        optimizationTask?.cancel()
    }

    private func finishVideoWork() {
        optimizationTask = nil
        isOptimizing = false
        isConverting = false
        optimizingEntryID = nil
        VideoWorkGate.shared.endWork()
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
