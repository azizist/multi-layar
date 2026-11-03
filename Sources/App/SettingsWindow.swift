import AppKit
import SwiftUI

/// Everything that used to live in the bottom half of the menu, plus how the
/// app looks and where it shows up.
@MainActor
final class SettingsWindowController {

    private let controls: Controls
    private var window: NSWindow?

    init(controls: Controls) {
        self.controls = controls
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingView(rootView: SettingsView(controls: controls))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

private struct SettingsView: View {
    @ObservedObject var controls: Controls

    var body: some View {
        let values = controls.values
        let actions = controls.actions
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { values.theme }, set: actions.setTheme)) {
                    Text("Light").tag(Theme.light)
                    Text("Dark").tag(Theme.dark)
                    Text("Match System").tag(Theme.system)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Show icon in menu bar",
                       isOn: Binding(get: { values.showMenuBarIcon }, set: actions.setShowMenuBarIcon))
                Picker("Show in Dock", selection: Binding(
                    get: { Preferences.dockIcon(chosen: values.dockIcon, menuBarIcon: values.showMenuBarIcon) },
                    set: actions.setDockIcon)) {
                    Text("While the window is open").tag(DockIcon.whileWindowOpen)
                    Text("Always").tag(DockIcon.always)
                }
                .disabled(!values.showMenuBarIcon)
            } header: {
                Text("Where it lives")
            } footer: {
                Text(values.showMenuBarIcon
                     ? "The window minimizes to the Dock. Closing it leaves the app running in the menu bar."
                     : "With the menu bar icon hidden, the Dock icon stays so you can always reopen the window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Start at login", isOn: controls.binding(\.startAtLogin, actions.toggleStartAtLogin))
                Toggle("Open the window when the app starts",
                       isOn: Binding(get: { values.openWindowAtLogin }, set: actions.setOpenWindowAtLogin))
            }

            Section {
                Toggle("Confirm before turning the built-in display off",
                       isOn: controls.binding(\.confirmDisplayOff, actions.toggleConfirmDisplayOff))
                Toggle("Restore sleep below 20% battery",
                       isOn: controls.binding(\.batteryFloor, actions.toggleBatteryFloor))
                LabeledContent("Emergency reset") {
                    Button("Copy Command", action: actions.copyResetCommand)
                }
            } header: {
                Text("Safety")
            } footer: {
                Text("If sleep ever stays disabled, paste the copied command into Terminal: sudo pmset -a disablesleep 0")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
