import SwiftUI

/// The same selection actions are available from the toolbar, context menus, and menu bar.
struct LibraryVideoActions {
    let store: LibraryStore
    let ids: Set<String>

    var hasSelection: Bool {
        !ids.isEmpty
    }
    var hasSingleSelection: Bool {
        ids.count == 1
    }
    var pair: VideoPairSelection? {
        store.pairAction(for: ids)
    }
    var optimizationTarget: VideoOptimizationTarget? {
        store.optimizationTarget(for: ids)
    }

    var useAsWallpaper: some View {
        Button("Use as Wallpaper…", systemImage: "desktopcomputer", action: store.openWallpaperSettings)
            .help("Phosphene wallpapers are selected in System Settings → Wallpaper")
    }

    var editPair: some View {
        let pair = self.pair
        let title = pair?.actionTitle ?? "Pair…"
        return Button {
            store.pairSheet = pair
        } label: {
            Label(title, image: .lightDarkPair)
        }
        .help(Text(title))
        .disabled(pair == nil)
    }

    @ViewBuilder
    var swapAppearances: some View {
        if let pair, pair.saved != nil, pair.members.count == 2 {
            Button("Swap Light and Dark", systemImage: "arrow.left.arrow.right") {
                store.swapAppearances(pair)
            }
        }
    }

    var showInFinder: some View {
        Button("Show in Finder", systemImage: "folder") { store.showInFinder(ids) }
            .help("Show in Finder")
    }

    var quickLook: some View {
        Button("Quick Look", systemImage: "eye") {
            let first = store.videoRows.first { ids.contains($0.id) }?.id ?? ids.sorted().first
            store.toggleQuickLook(first)
        }
    }

    var delete: some View {
        let title: LocalizedStringKey = if ids.count > 1 {
            "Delete \(ids.count) Videos…"
        } else if let id = ids.first, store.pairs[id] != nil {
            "Delete Pair…"
        } else {
            "Delete…"
        }
        return Button(title, systemImage: "trash", role: .destructive) { store.requestDelete(ids) }
    }

    @ViewBuilder
    var optimization: some View {
        if let target = optimizationTarget {
            Menu("Optimize", systemImage: "rectangle.compress.vertical") {
                if store.manager.optimizingEntryID == target.id {
                    let progress = store.manager.optimizationProgress.formatted(.percent.precision(.fractionLength(0)))
                    if store.manager.isConverting {
                        Text("Converting… \(progress)")
                    } else {
                        Text("Optimizing… \(progress)")
                    }
                    Button("Cancel", role: .destructive, action: store.manager.cancelOptimization)
                } else if !target.tiers.isEmpty {
                    if target.entry.sourceIsHDR == true {
                        Text(target.convertedToSDR ? "Optimized · SDR" : "Optimized · HDR")
                    }
                    ForEach(target.tiers, id: \.fps) { variant in
                        Text("\(variant.fps) fps · \(Int(variant.resolution.width)) × \(Int(variant.resolution.height))")
                    }
                } else if let error = target.eligibilityError {
                    Text(error.localizedDescription)
                } else if store.manager.isOptimizing {
                    Text("Wait for the current video to finish optimizing, then try again.")
                } else if target.storedTiers.isEmpty {
                    CreateVideoVariantActions(store: store, target: target)
                } else {
                    Menu("Regenerate Variants") {
                        CreateVideoVariantActions(store: store, target: target)
                    }
                }
                if !target.storedTiers.isEmpty, store.manager.optimizingEntryID != target.id {
                    Divider()
                    Button("Remove Variants…") { store.pendingVariantRemoval = target }
                }
            }
            .help("Optimize")
        }
    }
}

struct CreateVideoVariantActions: View {
    let store: LibraryStore
    let target: VideoOptimizationTarget

    var body: some View {
        if target.entry.sourceIsHDR == true {
            Toggle("Convert to SDR", isOn: Binding(
                get: { store.sdrOptimizationTargetID == target.id },
                set: { store.sdrOptimizationTargetID = $0 ? target.id : nil },
            ))
            Divider()
        }
        ForEach(OptimizationPreset.allCases) { preset in
            Button {
                store.manager.optimize(target, preset: preset, convertToSDR: store.sdrOptimizationTargetID == target.id)
            } label: {
                Text(preset.title)
                Text(preset.description)
            }
        }
    }
}
