import CoreImage
import QuartzCore
import Testing

@MainActor
struct ExternalWallpaperToneMapTests {
    @Test
    func `explicit HDR range updates a single filter on the scene root`() throws {
        let root = CALayer()
        let first = CALayer()
        let second = CALayer()
        root.addSublayer(first)
        root.addSublayer(second)
        var toneMap = ExternalWallpaperToneMap()

        let installed = toneMap.apply(to: root, mode: .standard, headroom: 7, isHDR: true)
        #expect(installed)
        #expect(root.filters?.count == 1)
        // Core Animation can return a CIFilter without the typed Core Image protocol.
        let initial = try #require(root.filters?.first as? CIFilter)
        try #require(initial.name == "CISystemToneMap")
        #expect(initial.value(forKey: "inputPreferredDynamicRange") as? String == CIDynamicRangeOption.standard.rawValue)
        #expect(initial.value(forKey: "inputDisplayHeadroom") as? Float == 7)
        #expect(first.filters == nil)
        #expect(second.filters == nil)
        let repeated = toneMap.apply(to: root, mode: .standard, headroom: 7, isHDR: true)
        #expect(!repeated)

        let modeChanged = toneMap.apply(to: root, mode: .constrainedHigh, headroom: 7, isHDR: true)
        #expect(modeChanged)
        let headroomChanged = toneMap.apply(to: root, mode: .constrainedHigh, headroom: 3, isHDR: true)
        #expect(headroomChanged)
        #expect(root.filters?.count == 1)
        let updated = try #require(root.filters?.first as? CIFilter)
        try #require(updated.name == "CISystemToneMap")
        #expect(updated.value(forKey: "inputPreferredDynamicRange") as? String == CIDynamicRangeOption.constrainedHigh.rawValue)
        #expect(updated.value(forKey: "inputDisplayHeadroom") as? Float == 3)
    }

    @Test(arguments: [HDRMode.standard, .constrainedHigh, .high])
    func `a pending variant keeps the HDR filter until its range is known`(mode: HDRMode) {
        let root = CALayer()
        var toneMap = ExternalWallpaperToneMap()

        let firstPending = toneMap.apply(to: root, mode: mode, headroom: 7, isHDR: nil)
        #expect(!firstPending)
        let installed = toneMap.apply(to: root, mode: mode, headroom: 7, isHDR: true)
        #expect(installed)
        let pendingHDR = toneMap.apply(to: root, mode: mode, headroom: 7, isHDR: nil)
        #expect(!pendingHDR)
        #expect(root.filters?.count == 1)
        let confirmedHDR = toneMap.apply(to: root, mode: mode, headroom: 7, isHDR: true)
        #expect(!confirmedHDR)
        let pendingSDR = toneMap.apply(to: root, mode: mode, headroom: 7, isHDR: nil)
        #expect(!pendingSDR)
        let confirmedSDR = toneMap.apply(to: root, mode: mode, headroom: 7, isHDR: false)
        #expect(confirmedSDR)
        #expect(root.filters == nil)
    }

    @Test
    func `automatic SDR and unavailable display headroom clear the filter`() {
        let root = CALayer()
        var toneMap = ExternalWallpaperToneMap()
        let fallbacks: [(HDRMode, Float?, Bool?)] = [
            (.automatic, 7, true),
            (.automatic, 7, nil),
            (.high, 7, false),
            (.high, nil, true),
            (.high, nil, nil),
            (.high, 1, true),
            (.high, .nan, true),
        ]
        for (mode, headroom, isHDR) in fallbacks {
            let installed = toneMap.apply(to: root, mode: .high, headroom: 7, isHDR: true)
            #expect(installed)
            let cleared = toneMap.apply(to: root, mode: mode, headroom: headroom, isHDR: isHDR)
            #expect(cleared)
            #expect(root.filters == nil)
            let repeated = toneMap.apply(to: root, mode: mode, headroom: headroom, isHDR: isHDR)
            #expect(!repeated)
        }
    }
}
