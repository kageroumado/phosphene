import Foundation

enum PathSafety {
    /// True if `id` is a well-formed UUID string — the only form a library
    /// entry directory ever takes. Rejecting non-UUID names neutralizes `..`,
    /// absolute paths, and stray files.
    static func isValidEntryID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// True if `name` is a safe single path component: a plain basename with no
    /// directory separators, no `.`/`..`, and no control characters.
    static func isSafeComponent(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return false }
        if name.contains("/") || name.contains("\\") { return false }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        return (name as NSString).lastPathComponent == name
    }

    /// Returns true only if, after standardizing `..` and symlinks, `child` is
    /// `base` itself or a descendant of it. The final gate before any filesystem
    /// mutation derived from untrusted metadata.
    static func contained(_ child: URL, in base: URL) -> Bool {
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
        return childPath == basePath || childPath.hasPrefix(basePath + "/")
    }
}
