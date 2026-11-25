import Propofol
import SwiftUI

struct DynamicRangePicker: View {
    @Binding var selection: HDRMode
    @State private var showsInfo = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            Text("Dynamic Range")
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Picker("Dynamic Range", selection: $selection) {
                Text("Automatic").tag(HDRMode.automatic)
                Text("Standard").tag(HDRMode.standard)
                Text("Constrained High").tag(HDRMode.constrainedHigh)
                Text("High").tag(HDRMode.high)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()

            Button("About Dynamic Range", systemImage: "info.circle") { showsInfo.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("About Dynamic Range")
                .popover(isPresented: $showsInfo) {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text("Dynamic Range").font(.headline)
                        Text("Automatic lets macOS choose the highlight brightness. Standard limits highlights to SDR white. Constrained High allows subdued HDR highlights.")
                        Text("High allows the brightest HDR highlights. GPU and power use can rise suddenly during HDR playback.")
                    }
                    .font(.callout)
                    .frame(width: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                }
        }
    }
}
