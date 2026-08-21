import Foundation

@main
enum ModifierHotkeyPermissionTests {
    static func main() throws {
        try assertEqual(
            ModifierHotkeyListenerStatus.evaluate(
                hasAccessibility: true,
                hasInputMonitoring: true,
                tapCreated: true,
                tapEnabled: false
            ),
            .tapDisabled,
            "a created-but-disabled event tap must not count as a live keyboard listener"
        )

        try assertEqual(
            ModifierHotkeyListenerStatus.evaluate(
                hasAccessibility: true,
                hasInputMonitoring: false,
                tapCreated: false,
                tapEnabled: false
            ),
            .needsInputMonitoring,
            "Input Monitoring must be diagnosed separately from Accessibility"
        )

        try assertEqual(
            ModifierHotkeyListenerStatus.evaluate(
                hasAccessibility: false,
                hasInputMonitoring: true,
                tapCreated: false,
                tapEnabled: false
            ),
            .needsAccessibility,
            "the modifier shortcut must preserve its Accessibility gate"
        )

        try assertEqual(
            ModifierHotkeyListenerStatus.evaluate(
                hasAccessibility: true,
                hasInputMonitoring: true,
                tapCreated: true,
                tapEnabled: true
            ),
            .ready,
            "both permissions and an enabled tap are required for readiness"
        )

        print("Modifier hotkey permission tests passed")
    }

    private static func assertEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String
    ) throws {
        guard actual == expected else {
            throw TestFailure(message: "\(message): expected \(expected), got \(actual)")
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
