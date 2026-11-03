import AppKit
import Combine
import SwiftUI

/// The main window, showing the 3D desk.
///
/// The renderer exists only while the window is open: closing it tears the
/// scene down. Minimized it stays, but renders only when the state changes.
/// The Dock icon is shown while the window exists and removed when it closes,
/// so the app is back to a plain menu bar item.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    private let devices: DeviceModel
    private let wallpaper = Wallpaper()
    private var window: NSWindow?
    private var renderer: SceneRenderer?
    private var subscription: AnyCancellable?

    private static let frameName = "MainWindow"

    init(devices: DeviceModel) {
        self.devices = devices
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if renderer == nil { attachScene(to: window) }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 450),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ClamshellKeeper"
        window.contentMinSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    private func attachScene(to window: NSWindow) {
        do {
            let renderer = try SceneRenderer()
            self.renderer = renderer
            renderer.setBackground(Self.background(for: window.effectiveAppearance))
            window.contentView = NSHostingView(rootView: DeskView(renderer: renderer, devices: devices))
            // Fires at once with the current state, which snaps into place.
            subscription = devices.$state.sink { [weak self] state in self?.render(state) }
        } catch {
            NSLog("ClamshellKeeper: 3D view unavailable: \(error)")
            window.contentView = NSHostingView(rootView: Text("The 3D view is not available on this Mac.")
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        }
    }

    private func render(_ state: DeviceState) {
        renderer?.show(state, wallpapers: wallpaper.current())
    }

    /// Coming back to the window is when a changed wallpaper or appearance
    /// gets picked up; neither sends a notification of its own.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window, let renderer else { return }
        renderer.setBackground(Self.background(for: window.effectiveAppearance))
        render(devices.state)
    }

    func windowWillClose(_ notification: Notification) {
        subscription = nil
        renderer = nil
        window?.contentView = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private static func background(for appearance: NSAppearance) -> CGColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? CGColor(gray: 0.16, alpha: 1)
            : CGColor(gray: 0.87, alpha: 1)
    }
}

private struct DeskView: View {
    @ObservedObject var renderer: SceneRenderer
    @ObservedObject var devices: DeviceModel
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
        .accessibilityLabel(devices.state.spokenSummary)
        .accessibilityAddTraits(.isImage)
    }

    private func resize(_ size: CGSize) {
        renderer.resize(width: Int(size.width * displayScale), height: Int(size.height * displayScale))
    }
}
