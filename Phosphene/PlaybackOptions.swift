import Propofol
import SwiftUI

struct DynamicRangePicker: View {
    @Binding var selection: HDRMode

    var body: some View {
        Picker("Dynamic Range", selection: $selection) {
            Text("Automatic").tag(HDRMode.automatic)
            Text("Standard").tag(HDRMode.standard)
            Text("Constrained High").tag(HDRMode.constrainedHigh)
            Text("High").tag(HDRMode.high)
        }
        .pickerStyle(.menu)
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

struct BlendMatchingFramesInfoButton: View {
    @State private var showsInfo = false

    var body: some View {
        Button("About Blend Matching Frames", systemImage: "info.circle") { showsInfo.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("About Blend Matching Frames")
            .popover(isPresented: $showsInfo) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Blend Matching Frames").font(.headline)
                    Text("Phosphene blends matching frames from the light and dark videos when appearance changes.")
                    Text("Both videos decode briefly at once. GPU and memory use can spike, especially with HDR, high frame rates, or multiple displays.")
                }
                .font(.callout)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
            }
    }
}
