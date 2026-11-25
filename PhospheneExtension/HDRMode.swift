import QuartzCore

nonisolated enum HDRMode: String, Sendable {
    case automatic
    case standard
    case constrainedHigh
    case high

    var dynamicRange: CALayer.DynamicRange {
        switch self {
        case .automatic: .automatic
        case .standard: .standard
        case .constrainedHigh: .constrainedHigh
        case .high: .high
        }
    }
}
