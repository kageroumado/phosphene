nonisolated struct ReportingConsent: Equatable {
    var crashReports = false
    var usageStatistics = false

    var storedValue: String {
        switch (crashReports, usageStatistics) {
        case (false, false): "off"
        case (false, true): "counting"
        case (true, false): "crashesOnly"
        case (true, true): "crashReports"
        }
    }
}

extension ReportingConsent {
    /// The original three preference values keep their meaning for existing installs.
    init?(storedValue: String?) {
        switch storedValue {
        case "off": self.init()
        case "counting": self.init(usageStatistics: true)
        case "crashesOnly": self.init(crashReports: true)
        case "crashReports": self.init(crashReports: true, usageStatistics: true)
        default: return nil
        }
    }
}
