enum ModifierHotkeyListenerStatus: Equatable {
    case needsAccessibility
    case needsInputMonitoring
    case tapUnavailable
    case tapDisabled
    case ready

    static func evaluate(
        hasAccessibility: Bool,
        hasInputMonitoring: Bool,
        tapCreated: Bool,
        tapEnabled: Bool
    ) -> Self {
        guard hasAccessibility else { return .needsAccessibility }
        guard hasInputMonitoring else { return .needsInputMonitoring }
        guard tapCreated else { return .tapUnavailable }
        guard tapEnabled else { return .tapDisabled }
        return .ready
    }
}
