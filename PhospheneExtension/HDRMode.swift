import QuartzCore

nonisolated enum HDRMode: String, Sendable {
    case automatic, standard, constrainedHigh, high

    var dynamicRange: CALayer.DynamicRange {
        switch self {
        case .automatic: .automatic
        case .standard: .standard
        case .constrainedHigh: .constrainedHigh
        case .high: .high
        }
    }
}
