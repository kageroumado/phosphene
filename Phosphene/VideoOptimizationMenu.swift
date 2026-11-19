import SwiftUI

struct VideoOptimizationMenu: View {
    let target: VideoOptimizationTarget
    let manager: PhospheneManager
    @Binding var convertToSDR: Bool
    let showUnavailable: (String) -> Void
    let requestRemoveVariants: () -> Void

    var body: some View {
        if let unavailableReason {
            Button { showUnavailable(unavailableReason) } label: { label }
                .help("Optimize")
        } else {
            Menu { commands } label: { label }
                .help("Optimize")
        }
    }

    private var label: some View {
        Label("Optimize", systemImage: "rectangle.compress.vertical")
    }

    private var unavailableReason: String? {
        if manager.optimizingEntryID == target.id {
            return manager.isCancellingOptimization ? String(localized: "Canceling Optimization…") : nil
        }
        guard target.tiers.isEmpty else { return nil }
        if let error = target.eligibilityError {
            return error.localizedDescription
        }
        return manager.isOptimizing ? String(localized: "Wait for the current video to finish optimizing, then try again.") : nil
    }

    @ViewBuilder
    private var commands: some View {
        if manager.optimizingEntryID == target.id {
            let progress = manager.optimizationProgress.formatted(.percent.precision(.fractionLength(0)))
            Text("Optimizing… \(progress)")
            Button("Cancel Optimization", role: .destructive) {
                manager.cancelOptimization(entryID: target.id)
            }
        } else if !target.tiers.isEmpty {
            if target.entry.sourceIsHDR == true {
                Text(target.convertedToSDR ? "Optimized · SDR" : "Optimized · HDR")
            } else {
                Text("Optimized")
            }
            ForEach(target.tiers, id: \.fps) { variant in
                let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).grouping(.never)
                let width = Double(variant.resolution.width).formatted(format)
                let height = Double(variant.resolution.height).formatted(format)
                Text("\(variant.fps) fps · \(width) × \(height)")
            }
            Divider()
            Button("Remove Variants…", role: .destructive, action: requestRemoveVariants)
        } else {
            if target.entry.sourceIsHDR == true {
                Toggle("Convert to SDR", isOn: $convertToSDR)
                Divider()
            }
            ForEach(OptimizationPreset.allCases) { preset in
                Button(preset.title) {
                    manager.optimize(target, preset: preset, convertToSDR: convertToSDR)
                }
            }
        }
    }
}
