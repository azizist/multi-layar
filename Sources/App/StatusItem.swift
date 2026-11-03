import AppKit
import ServiceManagement

/// The menu bar icon, the windows, and the policy that drives the helper.
///
/// "Armed" here is only ever a *request*. The helper decides, and it will
/// refuse or revoke whenever it cannot independently confirm that an external
/// display is attached and a console user is present.
final class AppController: NSObject, NSApplicationDelegate {

    private enum Key {
        static let keepAwake = "keepAwakeEnabled"
        static let batteryFloor = "batteryFloorPercent"
        static let skipDisplayConfirmation = "skipDisplayConfirmation"
    }
    private static let defaultBatteryFloor = 20

    private let client = DaemonClient()
    /// What the UI draws. Refreshed after every decision and helper reply.
    private let devices = DeviceModel()
    /// The switches every surface shows. Created first thing at launch.
    private var controls: Controls!
    // Created on first use. The controller predates them and is not
    // main-actor isolated, so it reaches each through one MainActor hop;
    // every caller is a main-thread callback.
    private var mainWindow: MainWindowController?
    private var popover: StatusPopover?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem!
    private var heartbeat: Timer?
    private var lastStatus: Wire.Status?
    private var helperReachable = true

    /// Deliberately NOT persisted, unlike keepAwake. If keepAwake survives a
    /// restart the worst case is a Mac that stayed awake; if this survived one,
    /// a black built-in panel would come back on its own at login, while an
    /// external is still negotiating its link after a cold boot.
    private var externalOnly = false
    private var displayReason = ""
    private var disableFailures = 0
    private var reconcilingDisplay = false
    private var hotkeyRegistered = false
    private var displayRetry: DispatchWorkItem?

    /// What the user asked for, remembered across restarts. Auto behaviour
    /// hangs off this: while it is on, the app arms whenever a monitor is
    /// attached and stands down the moment one is not.
    private var keepAwake: Bool {
        get { UserDefaults.standard.bool(forKey: Key.keepAwake) }
        set { UserDefaults.standard.set(newValue, forKey: Key.keepAwake) }
    }

    /// 0 means the floor is off. Off by default, deliberately: turning it on
    /// trades "runs the battery flat" for "stops working at 20%".
    private var batteryFloor: Int {
        get { UserDefaults.standard.integer(forKey: Key.batteryFloor) }
        set { UserDefaults.standard.set(newValue, forKey: Key.batteryFloor) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LoginItem.refreshIfRebuilt()
        controls = makeControls()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateIcon(armed: false)
        installMainMenu()

        // Put the built-in back before anything else, unconditionally. The
        // analogue of the helper's "first act on every load is disablesleep 0":
        // it makes "no black panel survives a restart" true by construction
        // rather than by trusting the OS to have reverted it.
        reconcileDisplay()

        DisplayWatcher.shared.start(
            onChange: { [weak self] _ in self?.push() },
            onSettled: { [weak self] in self?.reconcileDisplay() },
            onExternalLoss: { [weak self] in self?.reconcileDisplay() },
            onLidChange: { [weak self] in self?.reconcileDisplay() })

        hotkeyRegistered = Hotkey.register { [weak self] in self?.toggleExternalOnly() }

        // Never go to sleep with the built-in disabled. Sleep and clamshell
        // transitions renumber display IDs, and a disabled display is absent
        // from every public list, so waking up still disabled is the one state
        // the app can struggle to get out of. Restoring it first costs a
        // flicker on wake and removes the failure mode entirely.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                if !InternalDisplay.builtinIsActive() {
                    NSLog("ClamshellKeeper: restoring the built-in display before sleep")
                    InternalDisplay.enable(attempts: 2)
                }
            }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                // The helper's status is from before the sleep and says nothing
                // about what is plugged in now. Discard it so it cannot
                // authorise a disable; push() refreshes it a moment later.
                self?.lastStatus = nil
                self?.reconcileDisplay()
                self?.push()
            }

        // Display sleep changes nothing the controller acts on, but the UI
        // shows it, and no other callback fires for it.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.refreshDeviceState()
                }
        }

        // The heartbeat is the deadman switch: stop sending and the helper
        // restores normal sleep within a minute, whatever killed us.
        let timer = Timer(timeInterval: Wire.heartbeatInterval, repeats: true) {
            [weak self] _ in
            self?.push()
            // Also reconcile on a timer, not only on events. Reconciling is
            // idempotent, so this costs a state read when nothing is wrong —
            // and it means a missed reconfiguration callback self-heals within
            // one heartbeat instead of never.
            self?.reconcileDisplay()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        push()

        applyPreferences()
        if Preferences.openWindowAtLogin { openWindow() }
    }

    /// Clicking the Dock icon brings the window back, minimized or not.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best effort, and blocking on purpose: an async completion targeted at
        // the main queue would never run at this point. The helper's 60 s
        // timeout covers us anyway if this does not land.
        client.sendBlocking(.disarm)
        // macOS reverts an app-scoped display configuration when the process
        // dies — verified on this machine, including under SIGKILL — but a
        // clean quit should not rely on that.
        externalOnly = false
        if !InternalDisplay.builtinIsActive() { InternalDisplay.enable(attempts: 3) }
    }

    // MARK: - Built-in display

    /// Single entry point for every display decision. Idempotent against
    /// observed state, so the disable -> reconfiguration -> settle -> reconcile
    /// path terminates after one pass instead of oscillating.
    private func reconcileDisplay() {
        guard !reconcilingDisplay else { return }
        // Runs after any change below has been verified, so the UI only ever
        // sees the outcome, never the request.
        defer { refreshDeviceState() }

        let snapshot = DisplaySnapshot(
            builtinActive: InternalDisplay.builtinIsActive(),
            externalActive: InternalDisplay.activeExternalCount(),
            // Cross-check against the helper's own IOKit count: CoreGraphics
            // happily reports a Sidecar iPad or an AirPlay screen as external,
            // and neither is something you can count on still being there.
            physicalExternalConfirmed: (lastStatus?.externalDisplays ?? -1) >= 1,
            lidClosed: InternalDisplay.lidClosed(),
            mechanismAvailable: InternalDisplay.isAvailable,
            disableFailures: disableFailures)

        let (action, reason) = DisplayPolicy.decide(externalOnly: externalOnly, snapshot)
        displayReason = reason
        guard action != .none else { return }
        NSLog("ClamshellKeeper: \(action) — intent=\(externalOnly) builtinActive=\(snapshot.builtinActive) "
            + "externals=\(snapshot.externalActive) confirmed=\(snapshot.physicalExternalConfirmed) "
            + "lid=\(snapshot.lidClosed) failures=\(snapshot.disableFailures)")

        reconcilingDisplay = true
        defer {
            // Let the reconfiguration callbacks land before accepting another
            // decision, so a settle triggered by our own change is a no-op.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.reconcilingDisplay = false
            }
        }

        switch action {
        case .enable:
            if InternalDisplay.enable(attempts: 3) {
                disableFailures = 0
            } else {
                displayReason = "could not turn the built-in display back on"
                // Keep trying every second rather than waiting for the next
                // event or the 20s heartbeat. Terminates on its own: once the
                // panel is back, the next decision is .none.
                let retry = DispatchWorkItem { [weak self] in self?.reconcileDisplay() }
                displayRetry?.cancel()
                displayRetry = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
            }
        case .disable:
            if InternalDisplay.disable() {
                disableFailures = 0
            } else {
                disableFailures += 1
                externalOnly = disableFailures < DisplayPolicy.maxDisableFailures
            }
        case .none:
            break
        }
        updateIcon(armed: lastStatus?.armed == true)
    }

    /// Asks for confirmation on the display the user can still see, and reverts
    /// on its own if nobody answers.
    ///
    /// This exists for the one failure with no automatic detection: the external
    /// going dark without disconnecting — a monitor input switch, a KVM, or its
    /// own power button on a link that stays up. No event fires, so no code
    /// runs, and both panels are black. A countdown is the only thing that
    /// recovers it, and it is the same pattern macOS uses for resolution
    /// changes.
    private func confirmEngagement() {
        guard !UserDefaults.standard.bool(forKey: Key.skipDisplayConfirmation) else { return }

        let alert = NSAlert()
        alert.messageText = "Using the external display only"
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Turn Built-in Back On")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        var remaining = 15
        alert.informativeText = "Reverting in \(remaining) seconds if you can't see this."
        let countdown = Timer(timeInterval: 1, repeats: true) { timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                NSApp.abortModal()
            } else {
                alert.informativeText = "Reverting in \(remaining) seconds if you can't see this."
            }
        }
        // .common so it keeps firing inside the modal run loop.
        RunLoop.main.add(countdown, forMode: .common)

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        countdown.invalidate()

        if response == .alertFirstButtonReturn {
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Key.skipDisplayConfirmation)
            }
        } else {
            externalOnly = false
            reconcileDisplay()
        }
    }

    // MARK: - Talking to the helper

    /// Single place that decides what to ask for. Called on every display
    /// change, every toggle, and every heartbeat.
    private func push() {
        let external = DisplayWatcher.shared.externalCount
        let request: Wire.Request = (keepAwake && external > 0)
            ? .arm(external: external, batteryFloor: batteryFloor)
            : .disarm
        client.send(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let status):
                self.helperReachable = true
                self.lastStatus = status
                self.updateIcon(armed: status.armed)
            case .failure:
                self.helperReachable = false
                self.lastStatus = nil
                self.updateIcon(armed: false)
            }
            self.refreshDeviceState()
        }
    }

    private func refreshDeviceState() {
        let mode: LidClosedMode
        if !helperReachable {
            mode = .helperMissing
        } else if lastStatus?.armed == true {
            mode = .active
        } else if keepAwake, let reason = lastStatus?.reason, !reason.isEmpty {
            mode = .refused(reason)
        } else {
            mode = .off
        }
        devices.refresh(builtinNote: displayReason, lidClosedMode: mode)
        controls?.update(controlValues())
    }

    private func controlValues() -> Controls.Values {
        Controls.Values(keepAwake: keepAwake,
                        externalOnly: externalOnly,
                        batteryFloor: batteryFloor > 0,
                        startAtLogin: LoginItem.isEnabled,
                        confirmDisplayOff: !UserDefaults.standard.bool(forKey: Key.skipDisplayConfirmation),
                        hotkey: hotkeyRegistered ? Hotkey.displayName : nil,
                        theme: Preferences.theme,
                        showMenuBarIcon: Preferences.showMenuBarIcon,
                        dockIcon: Preferences.dockIcon,
                        openWindowAtLogin: Preferences.openWindowAtLogin)
    }

    private func updateIcon(armed: Bool) {
        statusItem.button?.image = MenuBarGlyph.image(armed: armed)
    }

    // MARK: - Windows and preferences

    private func makeControls() -> Controls {
        Controls(actions: .init(
            toggleKeepAwake: { [weak self] in self?.toggleKeepAwake() },
            toggleExternalOnly: { [weak self] in self?.toggleExternalOnly() },
            toggleBatteryFloor: { [weak self] in self?.toggleBatteryFloor() },
            toggleStartAtLogin: { [weak self] in self?.toggleLoginItem() },
            toggleConfirmDisplayOff: { [weak self] in self?.toggleConfirmDisplayOff() },
            copyResetCommand: { [weak self] in self?.copyEscapeHatch() },
            openWindow: { [weak self] in self?.openWindow() },
            openSettings: { [weak self] in self?.openSettings() },
            quit: { [weak self] in self?.quit() },
            setTheme: { [weak self] in Preferences.theme = $0; self?.applyPreferences() },
            setShowMenuBarIcon: { [weak self] in Preferences.showMenuBarIcon = $0; self?.applyPreferences() },
            setDockIcon: { [weak self] in Preferences.dockIcon = $0; self?.applyPreferences() },
            setOpenWindowAtLogin: { [weak self] in Preferences.openWindowAtLogin = $0; self?.applyPreferences() }))
    }

    private func applyPreferences() {
        statusItem.isVisible = Preferences.showMenuBarIcon
        switch Preferences.theme {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
        applyDockPolicy()
        MainActor.assumeIsolated { mainWindow?.appearanceChanged() }
        controls.update(controlValues())
    }

    /// A Dock icon while the main window exists, and always when chosen —
    /// or when the menu bar icon is hidden, since it is then the only way in.
    private func applyDockPolicy() {
        let windowOpen = MainActor.assumeIsolated { mainWindow?.isOpen ?? false }
        let dock = windowOpen || Preferences.effectiveDockIcon == .always
        NSApp.setActivationPolicy(dock ? .regular : .accessory)
    }

    /// The app menu and Window menu, so ⌘, ⌘Q ⌘M and ⌘W work while a window
    /// is in front. Without a main menu an accessory app has none of them.
    private func installMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Multi Layar"
        appMenu.addItem(withTitle: "About \(name)", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(quit), keyEquivalent: "q").target = self
        main.addItem(withTitle: name, action: nil, keyEquivalent: "").submenu = appMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Actions

    /// The standard panel: name, version and the copyright from Info.plist,
    /// plus a link to the source.
    @objc private func showAbout() {
        let link = "https://github.com/azizist/multi-layar"
        let credits = NSMutableAttributedString(string: "Source and releases:\n")
        credits.append(NSAttributedString(string: link, attributes: [.link: URL(string: link)!]))
        credits.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                             range: NSRange(location: 0, length: credits.length))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover() {
        refreshDeviceState()
        MainActor.assumeIsolated {
            if popover == nil { popover = StatusPopover(devices: devices, controls: controls) }
            if let button = statusItem.button { popover?.toggle(from: button) }
        }
    }

    @objc private func openWindow() {
        refreshDeviceState()
        MainActor.assumeIsolated {
            if mainWindow == nil {
                let window = MainWindowController(devices: devices, controls: controls)
                window.onClose = { [weak self] in self?.applyDockPolicy() }
                mainWindow = window
            }
            mainWindow?.show()
        }
    }

    @objc private func openSettings() {
        refreshDeviceState()
        MainActor.assumeIsolated {
            if settingsWindow == nil { settingsWindow = SettingsWindowController(controls: controls) }
            settingsWindow?.show()
        }
    }

    @objc private func toggleKeepAwake() {
        keepAwake.toggle()
        push()
    }

    @objc private func toggleExternalOnly() {
        if !externalOnly {
            // Refuse outright rather than arming the intent for later. Silently
            // remembering "external only" while nothing is plugged in means the
            // laptop screen goes black the next time you dock, without you
            // having touched anything — which is worse than doing nothing.
            guard InternalDisplay.isAvailable else {
                Toast.show("Turning the built-in display off isn't supported on this macOS version")
                return
            }
            guard DisplayWatcher.shared.externalCount > 0 else {
                Toast.show("No external display detected")
                return
            }
            guard !InternalDisplay.lidClosed() else {
                Toast.show("Open the lid first")
                return
            }
        }

        externalOnly.toggle()
        let wasActive = InternalDisplay.builtinIsActive()
        reconcileDisplay()

        if externalOnly {
            if wasActive, !InternalDisplay.builtinIsActive() {
                confirmEngagement()
            } else if InternalDisplay.builtinIsActive() {
                // Asked for, allowed, and still did not happen.
                externalOnly = false
                Toast.show(displayReason.isEmpty
                    ? "Couldn't turn the built-in display off"
                    : "Couldn't turn the built-in display off — \(displayReason)")
            }
        } else {
            Toast.show("Built-in display on")
        }
        // The intent can be reverted above after the reconcile already ran.
        refreshDeviceState()
    }

    @objc private func toggleBatteryFloor() {
        batteryFloor = batteryFloor > 0 ? 0 : Self.defaultBatteryFloor
        push()
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        refreshDeviceState()
    }

    private func toggleConfirmDisplayOff() {
        let skip = UserDefaults.standard.bool(forKey: Key.skipDisplayConfirmation)
        UserDefaults.standard.set(!skip, forKey: Key.skipDisplayConfirmation)
        refreshDeviceState()
    }

    /// The documented way out if this tool ever fails with the flag set.
    @objc private func copyEscapeHatch() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sudo pmset -a disablesleep 0", forType: .string)
        Toast.show("Reset command copied")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
