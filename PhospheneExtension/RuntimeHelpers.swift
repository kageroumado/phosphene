import Foundation
import IOSurface

/// Construct a WallpaperRemoteContextXPC wrapping the given CAContext ID.
/// The real class has a `box` ivar (or offset 8 fallback) containing a
/// WallpaperExtensionRemoteContext with a single UInt32 remoteContextID.
func createRemoteContextXPC(contextId: UInt32) -> AnyObject? {
    guard let realClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
          let raw = class_createInstance(realClass, 0) else {
        extensionLog("  ERROR: Could not create WallpaperRemoteContextXPC")
        return nil
    }

    let obj = raw as AnyObject
    let ptr = Unmanaged.passUnretained(obj).toOpaque()
    let ivarOffset: Int = if let ivar = class_getInstanceVariable(realClass, "box") {
        ivar_getOffset(ivar)
    } else {
        8
    }
    // Bounds-check before the raw write: if the runtime layout shrank or the
    // offset assumption is stale, writing past the instance would corrupt the
    // heap. Fail closed instead.
    guard ivarOffset >= 0,
          ivarOffset + MemoryLayout<UInt32>.size <= class_getInstanceSize(realClass) else {
        extensionLog("  ERROR: WallpaperRemoteContextXPC layout unexpected (offset \(ivarOffset), size \(class_getInstanceSize(realClass)))")
        return nil
    }
    ptr.advanced(by: ivarOffset).storeBytes(of: contextId, as: UInt32.self)
    traceLog("  Created WallpaperRemoteContextXPC (contextId: \(contextId), offset: \(ivarOffset))")
    return obj
}

/// Construct a WallpaperSnapshotXPC wrapping the given IOSurface.
/// The real class has a single `rawValue` ivar at offset 8 containing
/// a WallpaperSnapshot struct (8 bytes = IOSurface refcounted pointer).
func createSnapshotXPC(surface: IOSurface) -> AnyObject? {
    guard let snapshotXPCClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass,
          let instance = class_createInstance(snapshotXPCClass, 0) else {
        extensionLog("  [Snapshot] Failed to create WallpaperSnapshotXPC")
        return nil
    }

    // Offset 8 is the assumed `rawValue` ivar location. Verify the instance is
    // large enough to hold a pointer there before writing — a changed layout
    // must not turn into heap corruption.
    let snapshotOffset = 8
    guard snapshotOffset + MemoryLayout<UnsafeRawPointer>.size <= class_getInstanceSize(snapshotXPCClass) else {
        extensionLog("  [Snapshot] WallpaperSnapshotXPC layout unexpected (size \(class_getInstanceSize(snapshotXPCClass)))")
        return nil
    }

    let surfaceRef = Unmanaged.passRetained(surface).toOpaque()
    let instancePtr = Unmanaged.passUnretained(instance as AnyObject).toOpaque()
    instancePtr.advanced(by: snapshotOffset).storeBytes(of: surfaceRef, as: UnsafeRawPointer.self)
    return instance as AnyObject
}
