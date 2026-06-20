import Foundation
import Observation
import os

/// Notify-only update check against the public GitHub Releases of Phosphene.
///
/// Phosphene distributes notarized DMGs through GitHub Releases (and Homebrew,
/// where `brew upgrade` handles updates). Rather than bundle an in-app updater,
/// this performs one lightweight request to GitHub's `releases/latest` endpoint
/// and, when a newer version exists, exposes ``availableVersion`` so the menu
/// bar can offer a link to the releases page. It never downloads or installs.
@MainActor
@Observable
final class UpdateCheckService {
    /// The newer version (e.g. "1.1") when one is available, else `nil`.
    private(set) var availableVersion: String?

    /// Where the "update available" affordance sends the user.
    let releasesPageURL = URL(string: "https://github.com/kageroumado/phosphene/releases/latest")!

    @ObservationIgnored private let latestAPI = URL(
        string: "https://api.github.com/repos/kageroumado/phosphene/releases/latest")!
    @ObservationIgnored private let lastCheckKey = "UpdateCheck.lastCheck"
    @ObservationIgnored private let minInterval: TimeInterval = 60 * 60 * 24 // once/day

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Check at most once per `minInterval`. Safe to call on every launch.
    func checkIfDue() async {
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date.now.timeIntervalSince(last) < minInterval {
            return
        }
        await check()
    }

    /// Force a check now (e.g. a "Check for Updates" action), ignoring the interval.
    func check() async {
        var request = URLRequest(url: latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            UserDefaults.standard.set(Date.now, forKey: lastCheckKey)

            let latest = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName
            availableVersion = Self.isNewer(latest, than: currentVersion) ? latest : nil
        } catch {
            // Offline, rate-limited, or shape changed — stay quiet and retry later.
            Log.general.debug("Update check skipped: \(error.localizedDescription)")
        }
    }

    /// Numeric major.minor.patch comparison; missing components are treated as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let c = candidate.split(separator: ".").compactMap { Int($0) }
        let r = current.split(separator: ".").compactMap { Int($0) }
        for i in 0 ..< max(c.count, r.count) {
            let a = i < c.count ? c[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// Subset of GitHub's release JSON we care about.
private struct GitHubRelease: Decodable {
    let tagName: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}
