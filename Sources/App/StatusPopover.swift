import AppKit
import SwiftUI

/// The small panel under the menu bar icon: what is going on, the two
/// switches people reach for, and the way into the window and settings.
@MainActor
final class StatusPopover {

    private let popover = NSPopover()

    init(devices: DeviceModel, controls: Controls) {
        popover.behavior = .transient
        let view = PopoverView(devices: devices, controls: controls, close: { [weak popover] in
            popover?.performClose(nil)
        })
        popover.contentViewController = NSHostingController(rootView: view)
    }

    func toggle(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // A transient popover only closes on an outside click if the app is active.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

private struct PopoverView: View {
    @ObservedObject var devices: DeviceModel
    @ObservedObject var controls: Controls
    let close: () -> Void

    var body: some View {
        let state = devices.state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: state.lidClosedMode == .active ? "laptopcomputer" : "moon.zzz")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(StatusText.headline(state)).font(.headline)
                    Text(StatusText.detail(state)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let note = StatusText.note(state) {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(spacing: 0) {
                    SwitchRow(title: "Keep awake with lid closed",
                              isOn: controls.binding(\.keepAwake, controls.actions.toggleKeepAwake))
                    Divider()
                    // Closes first: turning the built-in off can put up a
                    // confirmation, which must not sit behind the popover.
                    SwitchRow(title: "External display only", shortcut: controls.values.hotkey,
                              isOn: controls.binding(\.externalOnly) {
                                  close()
                                  controls.actions.toggleExternalOnly()
                              })
                }
            }

            VStack(spacing: 0) {
                MenuRow(title: "Open Window…") { close(); controls.actions.openWindow() }
                MenuRow(title: "Settings…", shortcut: "⌘,") { close(); controls.actions.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Divider().padding(.vertical, 4)
                MenuRow(title: "Quit", shortcut: "⌘Q", action: controls.actions.quit)
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// A full-width menu-style button that highlights under the pointer.
private struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
