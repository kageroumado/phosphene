import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

nonisolated enum PairConverterRequest: Codable, Hashable {
    case blank
    case library(lightID: String, darkID: String, draftID: UUID)
}

@MainActor @Observable
final class ConversionToolModel {
    private(set) static var runningJobCount = 0
    let mode: ConversionMode
    private(set) var light: ConversionSource?
    private(set) var dark: ConversionSource?
    var assumeLightSDR = false
    var assumeDarkSDR = false
    var settings = ConversionSettings() {
        didSet {
            if settings.range != .sdr, settings.codec != .hevc {
                settings.codec = .hevc
            }
        }
    }
    var name = ""
    var addToLibrary: Bool
    private(set) var isRunning = false
    private(set) var progress = 0.0
    var errorMessage: String?
    private(set) var completionMessage: String?

    @ObservationIgnored private var preset = OptimizationPreset.quality
    @ObservationIgnored private var suggested = ConversionSettings()
    @ObservationIgnored private var suggestedName = ""
    @ObservationIgnored private var loadedPairDraft: UUID?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var jobID: UUID?
    @ObservationIgnored private var probes = [Bool: Task<Void, Never>]()
    private var loading = Set<Bool>()
    var isLoading: Bool {
        !loading.isEmpty
    }

    var needsFraming: Bool {
        guard settings.hasValidDimensions else { return false }
        return [light, dark].compactMap(\.self).contains { source in
            source.width * settings.height != source.height * settings.width
        }
    }

    init(mode: ConversionMode) {
        self.mode = mode
        addToLibrary = mode == .pair
    }

    var validationMessage: String? {
        guard !isLoading else { return String(localized: "Reading video information…") }
        guard let light, mode != .pair || dark != nil else {
            return mode == .pair ? String(localized: "Choose the light and dark source videos.") : String(localized: "Choose a source video.")
        }
        if light.range == nil && !assumeLightSDR || (mode == .pair && dark?.range == nil && !assumeDarkSDR) {
            return String(localized: "Confirm how to interpret the untagged source before converting.")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Enter an output name.")
        }
        do {
            try settings.validate(forPair: mode == .pair)
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    func chooseFile(dark: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectSource(url: url, name: url.deletingPathExtension().lastPathComponent, dark: dark)
    }

    func loadPair(_ request: PairConverterRequest) {
        guard case let .library(lightID, darkID, draftID) = request, draftID != loadedPairDraft else { return }
        loadedPairDraft = draftID
        let entries = VideoDeploymentService.listEntries()
        guard let light = entries.first(where: { $0.id == lightID }),
              let dark = entries.first(where: { $0.id == darkID }) else {
            errorMessage = String(localized: "One of the selected videos is no longer in the Library. Choose the sources again.")
            return
        }
        selectSource(light, dark: false)
        selectSource(dark, dark: true)
    }

    func selectSource(_ entry: VideoDeploymentService.EntryInfo, dark: Bool) {
        selectSource(url: VideoDeploymentService.videoURL(for: entry), name: entry.name, dark: dark)
    }

    private func selectSource(url: URL, name: String, dark isDark: Bool) {
        guard !isRunning, !isDark || mode == .pair else { return }
        probes[isDark]?.cancel()
        loading.insert(isDark)
        if isDark {
            dark = nil; assumeDarkSDR = false
        } else {
            light = nil; assumeLightSDR = false
        }
        completionMessage = nil
        errorMessage = nil
        probes[isDark] = Task {
            do {
                let source = try await ConversionSource.inspect(url: url, name: name)
                guard !Task.isCancelled else { return }
                if isDark {
                    dark = source
                } else {
                    light = source
                }
                updateSuggestions()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            loading.remove(isDark)
            probes[isDark] = nil
        }
    }

    private func suggestions() -> ConversionSettings {
        guard let reference = light ?? dark else { return ConversionSettings() }
        let sourceSize = CGSize(width: reference.width, height: reference.height)
        let size = preset.targetResolution(source: sourceSize)
        var result = ConversionSettings()
        result.width = max(2, Int(size.width) / 2 * 2)
        result.height = max(2, Int(size.height) / 2 * 2)
        let sourceFPS = reference.fps
        let tiers = VideoOptimizationService.computeFPSTiers(sourceRate: Float(min(1_000, sourceFPS)))
        switch preset {
        case .quality: result.fps = sourceFPS
        case .balanced: result.fps = tiers.dropFirst().first.map(Double.init) ?? sourceFPS
        case .batterySaver: result.fps = tiers.first(where: { $0 <= 30 }).map(Double.init) ?? min(30, sourceFPS)
        }
        result.fps = (result.fps * 1_000).rounded() / 1_000
        let bps = Double(result.width) * Double(result.height) * 2 * result.fps / 30
        result.bitrateMbps = max(0.01, (bps / 10_000).rounded() / 100)
        result.range = reference.range ?? .sdr
        result.codec = result.range == .sdr ? .h264 : .hevc
        result.duration = [light?.duration, dark?.duration].compactMap(\.self).min() ?? reference.duration
        return result
    }

    private func updateSuggestions() {
        let next = suggestions()
        var current = settings
        if current.width == suggested.width {
            current.width = next.width
        }
        if current.height == suggested.height {
            current.height = next.height
        }
        if current.fps == suggested.fps {
            current.fps = next.fps
        }
        if current.bitrateMbps == suggested.bitrateMbps {
            current.bitrateMbps = next.bitrateMbps
        }
        current.duration = next.duration
        if current.range == suggested.range {
            current.range = next.range
        }
        if current.codec == suggested.codec {
            current.codec = next.codec
        }
        settings = current
        suggested = next
        let sourceName = light?.name ?? dark?.name ?? ""
        let nextName = mode == .pair ? String(localized: "\(sourceName) Pair") : String(localized: "\(sourceName) Converted")
        if name == suggestedName {
            name = nextName
        }
        suggestedName = nextName
    }

    func applyPreset(_ preset: OptimizationPreset) {
        self.preset = preset
        let next = suggestions()
        // Presets set picture size, frame rate and bitrate.
        settings.width = next.width
        settings.height = next.height
        settings.fps = next.fps
        settings.bitrateMbps = next.bitrateMbps
        suggested = next
    }

    func start() {
        guard !isRunning, let light else { return }
        if let validationMessage {
            errorMessage = validationMessage; return
        }
        let sources = [light] + (mode == .pair ? [dark].compactMap(\.self) : [])
        let target = settings
        let outputName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let libraryOutput = mode == .pair || addToLibrary
        guard confirmUpgrades(sources, to: target) else { return }

        var destination: URL?
        if !libraryOutput {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = outputName.replacingOccurrences(of: "/", with: "-") + ".mp4"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard !PathSafety.contained(url, in: VideoDeploymentService.videosFolderURL),
                  sources.allSatisfy({ $0.url.resolvingSymlinksInPath().standardizedFileURL != url.resolvingSymlinksInPath().standardizedFileURL }) else {
                errorMessage = String(localized: "Choose a destination outside the managed Library and distinct from the source video.")
                return
            }
            destination = url
        }
        let output = destination.map { (url: $0, priorIdentity: FileIdentity(of: $0)) }
        let interpretations = [assumeLightSDR, assumeDarkSDR]
        let id = UUID()
        jobID = id
        progress = 0
        isRunning = true
        Self.runningJobCount += 1
        errorMessage = nil
        completionMessage = nil
        job = Task {
            defer {
                Self.runningJobCount -= 1
                isRunning = false
                job = nil
                jobID = nil
            }
            do {
                try await runConversion(sources, to: output, name: outputName, target: target, interpretations: interpretations, id: id)
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func runConversion(
        _ sources: [ConversionSource], to output: (url: URL, priorIdentity: FileIdentity?)?,
        name: String, target: ConversionSettings, interpretations: [Bool], id: UUID,
    ) async throws {
        let files = FileManager.default
        let scoped = sources.map(\.url).filter { $0.startAccessingSecurityScopedResource() }
        let destination = output?.url
        let outputScope = destination?.startAccessingSecurityScopedResource() ?? false
        defer {
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            if outputScope {
                destination?.stopAccessingSecurityScopedResource()
            }
        }
        let work = try files.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination?.deletingLastPathComponent() ?? files.temporaryDirectory,
            create: true,
        )
        defer { try? files.removeItem(at: work) }
        var outputs = [URL]()
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            guard FileIdentity(of: source.url) == source.identity else { throw PairIssue.changed }
            let out = work.appendingPathComponent(index == 0 ? "Light.mp4" : "Dark.mp4")
            try await VideoOptimizationService.convert(
                sourceURL: source.url, to: out, settings: target, forPair: mode == .pair, assumeSDR: interpretations[index],
            ) { value in
                guard self.jobID == id else { return }
                self.progress = max(self.progress, (Double(index) + value) / Double(sources.count))
            }
            guard FileIdentity(of: source.url) == source.identity else { throw PairIssue.changed }
            outputs.append(out)
        }
        try Task.checkCancellation()
        if let output {
            guard FileIdentity(of: output.url) == output.priorIdentity else {
                throw ConversionIssue(String(localized: "The destination changed during conversion. Choose it again."))
            }
            if output.priorIdentity == nil {
                guard unsafe renamex_np(outputs[0].path, output.url.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            } else {
                _ = try files.replaceItemAt(output.url, withItemAt: outputs[0])
            }
            completionMessage = String(localized: "Saved \(output.url.lastPathComponent).")
        } else {
            try await VideoDeploymentService.importConversion(light: outputs[0], dark: outputs.count == 2 ? outputs[1] : nil, name: name)
            completionMessage = String(localized: "Added \(name) to the Library.")
        }
        progress = 1
    }

    private func confirmUpgrades(_ sources: [ConversionSource], to target: ConversionSettings) -> Bool {
        let sections = sources.enumerated().compactMap { index, source -> String? in
            let changes = source.upgrades(to: target)
            guard !changes.isEmpty else { return nil }
            let heading = mode == .single ? source.name : (index == 0 ? String(localized: "Light · \(source.name)") : String(localized: "Dark · \(source.name)"))
            return ([heading] + changes.map { "• " + $0 }).joined(separator: "\n")
        }
        guard !sections.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Convert with these increases?")
        alert.informativeText = sections.joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    func cancel() {
        job?.cancel()
        probes.values.forEach { $0.cancel() }
        probes.removeAll()
        loading.removeAll()
    }
}
