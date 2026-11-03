import AppKit
import Combine
import SwiftUI

/// The main window: the 3D desk, the two devices' status, and the switches.
///
/// The renderer exists only while the window is open: closing it tears the
/// scene down. Minimized it stays, but renders only when the state changes.
/// The Dock icon is shown while the window exists; on close, `onClose` lets
/// the controller decide whether it stays.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    var onClose: () -> Void = {}

    private let devices: DeviceModel
    private let controls: Controls
    private let wallpaper = Wallpaper()
    private var window: NSWindow?
    private var renderer: SceneRenderer?
    private var subscription: AnyCancellable?

    private static let frameName = "MainWindow"

    init(devices: DeviceModel, controls: Controls) {
        self.devices = devices
        self.controls = controls
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if renderer == nil { attachScene(to: window) }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open or minimized; false once closed, when the scene is torn down.
    var isOpen: Bool { window?.contentView != nil }

    /// The theme changed; the scene's background and desk are not system colours.
    func appearanceChanged() {
        guard let window, let renderer else { return }
        renderer.setAppearance(dark: Self.isDark(window.effectiveAppearance))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Multi Layar"
        window.contentMinSize = NSSize(width: 520, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    private func attachScene(to window: NSWindow) {
        let renderer = try? SceneRenderer()
        if renderer == nil { NSLog("ClamshellKeeper: 3D view unavailable on this Mac") }
        self.renderer = renderer
        renderer?.setAppearance(dark: Self.isDark(window.effectiveAppearance))
        window.contentView = NSHostingView(rootView: MainView(renderer: renderer, devices: devices,
                                                              controls: controls))
        // Fires at once with the current state, which snaps into place.
        subscription = devices.$state.sink { [weak self] state in self?.render(state) }
    }

    private func render(_ state: DeviceState) {
        renderer?.show(state, wallpapers: wallpaper.current())
    }

    /// Coming back to the window is when a changed wallpaper or system
    /// appearance gets picked up; neither sends a notification of its own.
    func windowDidBecomeKey(_ notification: Notification) {
        appearanceChanged()
        render(devices.state)
    }

    func windowWillClose(_ notification: Notification) {
        subscription = nil
        renderer = nil
        window?.contentView = nil
        onClose()
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

private struct MainView: View {
    let renderer: SceneRenderer?
    @ObservedObject var devices: DeviceModel
    @ObservedObject var controls: Controls

    var body: some View {
        let state = devices.state
        VStack(spacing: 14) {
            ZStack(alignment: .topLeading) {
                if let renderer {
                    DeskView(renderer: renderer, summary: state.spokenSummary)
                } else {
                    Text("The 3D view isn't available on this Mac.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let arrangement = StatusText.arrangement(state.shownExternal?.layout) {
                    Text("\(arrangement) · from Displays settings")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .padding(12)
                }
            }
            .frame(minHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                let laptop = StatusText.laptop(state)
                DeviceCard(symbol: "laptopcomputer", title: "MacBook", status: laptop.0, dot: laptop.1)
                let external = StatusText.external(state.shownExternal)
                DeviceCard(symbol: "display", title: external.0, status: external.1, dot: external.2)
            }

            GroupBox {
                VStack(spacing: 0) {
                    SwitchRow(title: "Keep awake with lid closed",
                              detail: "Works on battery while an external display is connected",
                              isOn: controls.binding(\.keepAwake, controls.actions.toggleKeepAwake))
                    Divider()
                    SwitchRow(title: "Use external display only", shortcut: controls.values.hotkey,
                              isOn: controls.binding(\.externalOnly, controls.actions.toggleExternalOnly))
                    Divider()
                    SwitchRow(title: "Restore sleep below 20% battery",
                              isOn: controls.binding(\.batteryFloor, controls.actions.toggleBatteryFloor))
                }
            }

            HStack {
                Text(StatusText.note(state) ?? StatusText.detail(state))
                Spacer()
                Button("Settings…", action: controls.actions.openSettings)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

/// The scene as an image, sized to the view in pixels.
private struct DeskView: View {
    @ObservedObject var renderer: SceneRenderer
    let summary: String
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = renderer.image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { resize(proxy.size) }
            .onChange(of: proxy.size) { _, size in resize(size) }
            .onChange(of: displayScale) { _, _ in resize(proxy.size) }
        }
        // The scene is a picture; VoiceOver gets the same facts in words.
        .accessibilityElement()
        .accessibilityLabel(summary)
        .accessibilityAddTraits(.isImage)
    }

    private func resize(_ size: CGSize) {
        renderer.resize(width: Int(size.width * displayScale), height: Int(size.height * displayScale))
    }
}

struct DeviceCard: View {
    let symbol: String
    let title: String
    let status: String
    let dot: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct SwitchRow: View {
    let title: String
    var detail: String? = nil
    var shortcut: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        .accessibilityLabel("Shortcut \(shortcut)")
                }
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}
