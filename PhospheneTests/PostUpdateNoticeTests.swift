import Testing

@Suite("Post-update notice")
struct PostUpdateNoticeTests {
    @Test
    func `an older notice is retired and stays gone after relaunch`() {
        var storedVersion: String? = "1.9.0"
        let notice = PostUpdateNotice.reconcile(
            recordedVersion: storedVersion,
            runningVersion: "1.10.0",
            acknowledge: { storedVersion = nil },
        )
        #expect(notice == nil)
        #expect(storedVersion == nil)

        let relaunchedNotice = PostUpdateNotice.reconcile(
            recordedVersion: storedVersion,
            runningVersion: "1.10.0",
            acknowledge: { Issue.record("An absent notice needs no acknowledgement") },
        )
        #expect(relaunchedNotice == nil)
    }

    @Test
    func `a notice for the running version is kept until the user acknowledges it`() {
        let notice = PostUpdateNotice.reconcile(
            recordedVersion: "1.10.0",
            runningVersion: "1.10.0",
            acknowledge: { Issue.record("The current notice must remain unacknowledged") },
        )
        #expect(notice == "1.10.0")
    }

    @Test(arguments: ["1.8.0", "1.10.0", "", nil] as [String?])
    func `a mismatched or missing running version cannot announce a successful update`(runningVersion: String?) {
        var acknowledged = false
        let notice = PostUpdateNotice.reconcile(
            recordedVersion: "1.9.0",
            runningVersion: runningVersion,
            acknowledge: { acknowledged = true },
        )
        #expect(notice == nil)
        #expect(acknowledged)
    }
}
