import Foundation

/// Reference-counting wrapper around security-scoped resource access.
@MainActor
final class SecurityScopedResourceManager {
    static let shared = SecurityScopedResourceManager()

    private var activeResources: [URL: Int] = [:]

    private init() {}

    /// Request access to a security-scoped resource.
    /// Returns true if access was granted or already active.
    func requestAccess(to url: URL) -> Bool {
        if let count = activeResources[url] {
            activeResources[url] = count + 1
            return true
        }

        let granted = url.startAccessingSecurityScopedResource()
        if granted {
            activeResources[url] = 1
        }
        return granted
    }

    /// Release access to a security-scoped resource.
    func releaseAccess(to url: URL) {
        guard let count = activeResources[url] else { return }

        if count > 1 {
            activeResources[url] = count - 1
        } else {
            url.stopAccessingSecurityScopedResource()
            activeResources.removeValue(forKey: url)
        }
    }

    /// Perform an operation with guaranteed security-scoped access.
    func withAccess<T>(to url: URL, perform operation: () throws -> T) rethrows -> T {
        let granted = requestAccess(to: url)
        defer {
            if granted {
                releaseAccess(to: url)
            }
        }
        return try operation()
    }

    /// Async version of withAccess.
    func withAccess<T>(to url: URL, perform operation: () async throws -> T) async rethrows -> T {
        let granted = requestAccess(to: url)
        defer {
            if granted {
                releaseAccess(to: url)
            }
        }
        return try await operation()
    }
}
