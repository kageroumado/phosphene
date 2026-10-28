import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Adds a video file to the Phosphene library. Choosing it as the wallpaper happens
/// in System Settings › Wallpaper, per display and per desktop.
///
/// Keep the type name: App Intents identifies an action by it, so renaming the type
/// would break every shortcut that already uses this action.
struct SetWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Video to Phosphene"
    static let description = IntentDescription(
        "Adds a video to your Phosphene library. Choose it as your wallpaper in System Settings › Wallpaper.",
    )

    @Parameter(title: "Video", description: "The video file to add", supportedContentTypes: [.movie])
    var video: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$video) to Phosphene")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let filename = video.fileURL?.lastPathComponent ?? video.filename
        guard PathSafety.isSafeComponent(filename) else {
            return .result(dialog: "Phosphene can’t add a file named “\(filename)”.")
        }
        if let existing = VideoDeploymentService.listEntries().first(where: { $0.filename == filename }) {
            return .result(dialog: "“\(existing.name)” is already in your Phosphene library. Choose it in System Settings › Wallpaper.")
        }

        let id: String?
        if let url = video.fileURL {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            id = await VideoDeploymentService.deployVideo(url: url)
        } else {
            // A file shared as data (from another action or app) is written out under its
            // own name, so the library dedups it by filename like any other video.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let url = folder.appendingPathComponent(filename)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try video.data.write(to: url)
            } catch {
                return .result(dialog: "Phosphene couldn’t read “\(filename)”.")
            }
            id = await VideoDeploymentService.deployVideo(url: url)
        }

        guard let id, let entry = VideoDeploymentService.listEntries().first(where: { $0.id == id }) else {
            return .result(dialog: "Phosphene couldn’t add “\(filename)” to the library.")
        }
        return .result(dialog: "Added “\(entry.name)” to your Phosphene library. Choose it in System Settings › Wallpaper.")
    }
}
