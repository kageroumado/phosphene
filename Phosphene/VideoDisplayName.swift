import Foundation

/// Turns a downloaded video's file-name slug into a human title:
/// "mornye-galaxy-stars-wuthering-waves-moewalls-com" → "Mornye Galaxy Stars Wuthering Waves".
/// Applied once — at import, and by the legacy-name migration — so the stored `name`
/// is the display name everywhere, including the System Settings wallpaper picker.
enum VideoDisplayName {
    private static let siteSuffixes = [
        "-moewalls-com", "-moewalls",
        "_moewalls_com", "_moewalls",
        "-motionbgs-com", "-motionbgs",
    ]

    static func pretty(from raw: String) -> String {
        var name = raw
        let lowered = name.lowercased()
        for suffix in siteSuffixes where lowered.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }

        // Already a human name: has spaces and no slug separators — keep as typed.
        if name.contains(" "), !name.contains("-"), !name.contains("_") {
            return name
        }

        let words = name
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? raw : joined
    }
}
