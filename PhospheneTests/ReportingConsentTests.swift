import Testing

struct ReportingConsentTests {
    @Test(arguments: [
        ("off", false, false),
        ("counting", false, true),
        ("crashesOnly", true, false),
        ("crashReports", true, true),
    ])
    func `stored consent preserves each grant`(value: String, crashReports: Bool, usageStatistics: Bool) throws {
        let consent = try #require(ReportingConsent(storedValue: value))
        #expect(consent.crashReports == crashReports)
        #expect(consent.usageStatistics == usageStatistics)
        #expect(consent.storedValue == value)
    }

    @Test
    func `either grant can be withdrawn independently`() throws {
        var consent = try #require(ReportingConsent(storedValue: "crashReports"))
        consent.usageStatistics = false
        #expect(consent.storedValue == "crashesOnly")

        consent.usageStatistics = true
        consent.crashReports = false
        #expect(consent.storedValue == "counting")
    }

    @Test
    func `missing and unknown consent can still be requested`() {
        #expect(ReportingConsent(storedValue: nil) == nil)
        #expect(ReportingConsent(storedValue: "unknown") == nil)
        #expect(ReportingConsent(storedValue: "off") != nil)
    }
}
