import AppKit

enum SidecarDisplay {
    static let connectedDevicesChanged = Notification.Name("SidecarDisplayManagerConnectedDevicesChangedNotification")

    static func isIPad(_ id: CGDirectDisplayID, name: String) -> Bool {
        // Sidecar advertises the FourCCs 'aapl' and 'iPad' even when the display is renamed.
        (id != 0 && CGDisplayVendorNumber(id) == 0x6161_706C && CGDisplayModelNumber(id) == 0x6950_6164)
            || name.localizedCaseInsensitiveContains("iPad")
            || name.localizedCaseInsensitiveContains("Sidecar Display")
    }

    /// NSScreen reports the virtual display's product name. The connected Sidecar session
    /// supplies the device name and the Core Graphics display ID it belongs to.
    static func connectedNames() -> [CGDirectDisplayID: String] {
        let shared = NSSelectorFromString("sharedManager")
        let configForDevice = NSSelectorFromString("configForDevice:")
        guard let managerClass, managerClass.responds(to: shared),
              let manager = unsafe managerClass.perform(shared)?.takeUnretainedValue() as? NSObject,
              manager.responds(to: configForDevice),
              manager.responds(to: NSSelectorFromString("connectedDevices")),
              let devices = manager.value(forKey: "connectedDevices") as? [NSObject] else { return [:] }

        var names: [CGDirectDisplayID: String] = [:]
        for device in devices {
            guard device.responds(to: NSSelectorFromString("name")),
                  let name = device.value(forKey: "name") as? String, !name.isEmpty,
                  let config = unsafe manager.perform(configForDevice, with: device)?.takeUnretainedValue() as? NSObject,
                  config.responds(to: NSSelectorFromString("displayID")),
                  let id = config.value(forKey: "displayID") as? CGDirectDisplayID, id != 0 else { continue }
            names[id] = name
        }
        return names
    }

    private static let managerClass: NSObject.Type? = {
        let framework = Bundle(path: "/System/Library/PrivateFrameworks/SidecarCore.framework")
        return framework?.classNamed("SidecarDisplayManager") as? NSObject.Type
    }()
}
