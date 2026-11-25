import IOKit.ps
import SwiftUI

/// The displays and Spaces using the selected video or appearance pair.
struct InspectorDisplayStrip: View {
    typealias Selection = WallpaperPrefsService.WallpaperSelection
    let selections: [Selection]

    var body: some View {
        let displays = selections.reduce(into: [Selection]()) { result, selection in
            if !result.contains(where: { $0.displayUUID == selection.displayUUID }) {
                result.append(selection)
            }
        }
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(displays, id: \.displayUUID) { display in
                    let spaces = selections.filter { $0.displayUUID == display.displayUUID }.compactMap(\.spaceName)
                    let name = ([display.displayName] + spaces).joined(separator: " · ")
                    let description = Text("In use on \(name)")
                    VStack(spacing: 2) {
                        Image(systemName: symbol(for: display))
                            .font(.system(size: 18))
                        Text(verbatim: display.displayName)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in
                        displays.count == 1 ? width : min(width, 76)
                    }
                    .help(description)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(description)
                }
            }
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func symbol(for display: Selection) -> String {
        if display.displayID != 0, CGDisplayIsBuiltin(display.displayID) != 0 {
            return Self.hasInternalBattery ? "macbook" : "desktopcomputer"
        }
        if SidecarDisplay.isIPad(display.displayID, name: display.displayName) {
            return "ipad.landscape"
        }
        return "display"
    }

    private static let hasInternalBattery: Bool = {
        guard let info = unsafe IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = unsafe IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [AnyObject] else { return false }
        return sources.contains { source in
            let details = unsafe IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return details?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()
}
