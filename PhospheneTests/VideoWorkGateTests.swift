import Testing

@MainActor
struct VideoWorkGateTests {
    @Test
    func `all video jobs must finish before replacement can reserve the app`() throws {
        let gate = VideoWorkGate()
        var canReplaceApp = [Bool]()
        gate.onWorkChanged = { [unowned gate] in
            canReplaceApp.append(gate.canReplaceApp)
        }

        try #require(gate.beginWork())
        try #require(gate.beginWork())
        #expect(!gate.beginReplacement())
        gate.endWork()
        #expect(!gate.beginReplacement())
        gate.endWork()
        #expect(canReplaceApp == [false, false, false, true])

        try #require(gate.beginReplacement())
        #expect(!gate.beginWork())
        #expect(!gate.beginReplacement())
        gate.endReplacement()
        try #require(gate.beginWork())
        gate.endWork()
    }
}
