import Propofol
import SwiftUI

struct PopoverSettingPicker<Selection: Hashable, Options: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Selection
    let inactiveSelection: Selection
    @ViewBuilder var options: Options
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isActive = selection != inactiveSelection
        HStack(spacing: Theme.Space.sm) {
            Text(title)
                .font(.caption)
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.vertical, Theme.Space.sm)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Picker(title, selection: $selection) { options }
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, Theme.Space.sm)
        .glassEffect(
            isActive ? .regular.tint(Color.accentColor.opacity(0.35)) : .regular,
            in: Theme.concentricInnerShape,
        )
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: isActive)
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
                    Text("In Everywhere mode, matching frames can smooth the switch between light and dark as the wallpaper plays. You may still see some ghosting.")
                    Text("In Lock Screen and Paused modes, the desktop shows a still frame and usually doesn’t need blending.")
                    Text("Both videos decode briefly at once. GPU and memory use can spike, especially with HDR, high frame rates, or multiple displays.")
                }
                .font(.callout)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
            }
    }
}
