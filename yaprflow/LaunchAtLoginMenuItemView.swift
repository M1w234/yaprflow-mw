import AppKit
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "LaunchAtLogin")

@MainActor
final class LaunchAtLoginMenuItemView: MenuRowView {
    private enum DisplayStatus: Equatable, Sendable {
        case off
        case on
        case needsApproval
    }

    /// `SMAppService.mainApp.status` is unexpectedly expensive on some Macs
    /// (hundreds of milliseconds). NSMenu attaches all view-backed rows before
    /// it becomes visible, so reading that property from `refresh()` made every
    /// menu click wait for the system service. Render the last known value
    /// immediately and update it off the main actor instead.
    private var cachedStatus: DisplayStatus = .off
    private var statusRefreshTask: Task<Void, Never>?

    init() {
        super.init(symbolName: "power", title: "Launch at Login")
        refreshStatusAsynchronously()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            refreshStatusAsynchronously()
        }
    }

    override func refresh() {
        switch cachedStatus {
        case .on:            stateField.stringValue = "On"
        case .needsApproval: stateField.stringValue = "Needs approval"
        case .off:           stateField.stringValue = "Off"
        }
    }

    override func applyStateColor() {
        stateField.textColor = (cachedStatus == .needsApproval)
            ? .systemOrange
            : .secondaryLabelColor
    }

    override func rowClicked() {
        let service = SMAppService.mainApp
        do {
            switch cachedStatus {
            case .on:
                try service.unregister()
                cachedStatus = .off
            case .needsApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .off:
                try service.register()
                // Registration normally takes effect immediately. The
                // background refresh below corrects this if macOS instead
                // requires approval.
                cachedStatus = .on
            }
        } catch {
            log.error("Toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        reload()
        refreshStatusAsynchronously()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    private func refreshStatusAsynchronously() {
        guard statusRefreshTask == nil else { return }
        statusRefreshTask = Task { [weak self] in
            let latest = await Task.detached(priority: .utility) {
                switch SMAppService.mainApp.status {
                case .enabled:          return DisplayStatus.on
                case .requiresApproval: return DisplayStatus.needsApproval
                default:                return DisplayStatus.off
                }
            }.value

            guard let self else { return }
            self.cachedStatus = latest
            self.statusRefreshTask = nil
            self.reload()
        }
    }
}
