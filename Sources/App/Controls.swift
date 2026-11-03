import Combine
import SwiftUI

/// The switches every surface shows — window, popover and settings — and
/// what pressing them does.
///
/// It decides nothing: the values are pushed in by AppController after each
/// change has run its course, and every action goes back through
/// AppController's existing paths, refusals and confirmations included.
final class Controls: ObservableObject {

    struct Values: Equatable {
        var keepAwake = false
        var externalOnly = false
        var batteryFloor = false
        var startAtLogin = false
        var confirmDisplayOff = true
        /// nil when the global shortcut could not be registered.
        var hotkey: String?
        var theme = Theme.system
        var showMenuBarIcon = true
        var dockIcon = DockIcon.whileWindowOpen
        var openWindowAtLogin = false
    }

    struct Actions {
        var toggleKeepAwake: () -> Void
        var toggleExternalOnly: () -> Void
        var toggleBatteryFloor: () -> Void
        var toggleStartAtLogin: () -> Void
        var toggleConfirmDisplayOff: () -> Void
        var copyResetCommand: () -> Void
        var openWindow: () -> Void
        var openSettings: () -> Void
        var quit: () -> Void
        var setTheme: (Theme) -> Void
        var setShowMenuBarIcon: (Bool) -> Void
        var setDockIcon: (DockIcon) -> Void
        var setOpenWindowAtLogin: (Bool) -> Void
    }

    @Published private(set) var values = Values()
    let actions: Actions

    init(actions: Actions) {
        self.actions = actions
    }

    func update(_ next: Values) {
        if next != values { values = next }
    }

    /// A switch that shows the current value and, when flipped, asks for the
    /// change rather than setting it — the value only moves once it happened.
    func binding(_ value: KeyPath<Values, Bool>, _ action: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { self.values[keyPath: value] }, set: { _ in action() })
    }
}

/// Lines shared by the window and the popover.
enum StatusText {

    static func headline(_ state: DeviceState) -> String {
        switch state.lidClosedMode {
        case .helperMissing: return "Helper not running"
        case .active: return "Staying awake with the lid closed"
        case .refused: return "Lid-closed mode is waiting"
        case .off: return "Normal sleep"
        }
    }

    static func detail(_ state: DeviceState) -> String {
        let connected = state.externals.filter { $0.connection != .disconnected }.count
        let externals = connected == 1 ? "1 external" : "\(connected) externals"
        let battery = state.batteryPercent.map { "\($0)%" } ?? "—"
        return "\(externals) · \(battery) on \(state.onAC ? "AC" : "battery")"
    }

    /// Why something is not as asked, if there is a reason worth showing.
    static func note(_ state: DeviceState) -> String? {
        if case .helperMissing = state.lidClosedMode { return "The background helper isn't running — see the README." }
        if case .refused(let reason) = state.lidClosedMode { return "Lid-closed mode: \(reason)" }
        return state.builtinNote.isEmpty ? nil : "Built-in display: \(state.builtinNote)"
    }

    static func laptop(_ state: DeviceState) -> (String, Color) {
        if state.lidClosed {
            if case .active = state.lidClosedMode { return ("Lid closed · staying awake", .green) }
            return ("Lid closed", .secondary)
        }
        switch state.builtinScreen {
        case .on: return ("Lid open · display on", .green)
        case .off: return ("Lid open · display off", .secondary)
        case .asleep: return ("Lid open · display asleep", .secondary)
        }
    }

    static func external(_ display: ExternalDisplay?) -> (String, String, Color) {
        guard let display else { return ("No external display", "Connect one to use these features", .secondary) }
        switch display.connection {
        case .on: return (display.name, "Connected · on", .green)
        case .asleep: return (display.name, "Connected · asleep", .secondary)
        case .disconnected:
            let place = display.layout.map { " · last seen \($0.summary)" } ?? ""
            return (display.name, "Disconnected\(place)", .orange)
        }
    }

    static func arrangement(_ layout: DisplayLayout?) -> String? {
        switch layout {
        case .beside(.left, _)?: return "Side by side · external on the left"
        case .beside(.right, _)?: return "Side by side · external on the right"
        case .beside(.above, _)?: return "Stacked · external on top"
        case .beside(.below, _)?: return "Stacked · external below"
        case .mirrored?: return "Mirrored"
        case nil: return nil
        }
    }
}
