public struct SessionAppearance: Sendable {
    public let color: Int
    public let effect: OAI.Effect
    public let speed: Double

    public init(status: SessionStatus) {
        switch status {
        case .working:
            (color, effect, speed) = (0x00B0FF, .shallowBreath, 0.25)
        case .blocked:
            (color, effect, speed) = (0xFFA000, .breath, 0.5)
        case .done:
            (color, effect, speed) = (0x00C853, .solid, 0.5)
        case .idle:
            (color, effect, speed) = (0xA58BC4, .solid, 0.5)
        case .error:
            (color, effect, speed) = (0xFF3B30, .solid, 0.5)
        case .unknown:
            (color, effect, speed) = (0x666666, .solid, 0.5)
        }
    }
}
