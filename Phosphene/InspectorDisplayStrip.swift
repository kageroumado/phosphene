import IOKit.ps
import SwiftUI

struct InspectorDisplayStrip: View {
    typealias Selection = WallpaperPrefsService.WallpaperSelection
    let selections: [Selection]

    private var displays: [Selection] {
        var seen = Set<String>()
        return selections.filter { seen.insert($0.displayUUID).inserted }
    }

    var body: some View {
        let displays = self.displays
        if displays.isEmpty {
            Color.clear.accessibilityHidden(true).allowsHitTesting(false)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(displays, id: \.displayUUID) { display in
                        let description = usageDescription(for: display)
                        VStack(spacing: 2) {
                            Image(systemName: symbol(for: display))
                                .font(.system(size: 18))
                                .frame(height: 20)
                            Text(verbatim: display.displayName)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .containerRelativeFrame(.horizontal) { width, _ in
                            displays.count == 1 ? width : min(width, 76)
                        }
                        .help(description)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: description))
                    }
                }
            }
            .defaultScrollAnchor(.center, for: .alignment)
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func usageDescription(for display: Selection) -> String {
        let spaces = selections.filter { $0.displayUUID == display.displayUUID }.compactMap(\.spaceName)
        let name = ([display.displayName] + spaces).joined(separator: " · ")
        return String(localized: "In use on \(name)")
    }

    private func symbol(for display: Selection) -> String {
        if display.displayID != 0, CGDisplayIsBuiltin(display.displayID) != 0 {
            return Self.hasInternalBattery ? "macbook" : "desktopcomputer"
        }
        if display.displayName.localizedCaseInsensitiveContains("iPad") {
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
