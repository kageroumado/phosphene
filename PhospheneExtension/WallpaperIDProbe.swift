import Foundation

/// The `WallpaperID` UUID inside a WallpaperIDXPC (`box.rawValue.id`), or nil. Returns the
/// first UUID found in the Mirror tree.
func extractWallpaperUUID(fromID id: Any?) -> UUID? {
    guard let id else { return nil }
    return searchUUID(id, depth: 0)
}

private func searchUUID(_ value: Any, depth: Int) -> UUID? {
    guard depth < 8 else { return nil }
    if let u = value as? UUID { return u }
    for child in Mirror(reflecting: value).children {
        if let found = searchUUID(child.value, depth: depth + 1) { return found }
    }
    return nil
}
