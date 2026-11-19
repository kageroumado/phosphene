import os

nonisolated enum Log {
    static let general = Logger(subsystem: "glass.kagerou.phosphene", category: "General")
    static let video = Logger(subsystem: "glass.kagerou.phosphene", category: "Video")
    static let storage = Logger(subsystem: "glass.kagerou.phosphene", category: "Storage")
    static let login = Logger(subsystem: "glass.kagerou.phosphene", category: "LaunchAtLogin")
    static let update = Logger(subsystem: "glass.kagerou.phosphene", category: "Update")
}
