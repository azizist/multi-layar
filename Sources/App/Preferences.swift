import Foundation

enum Theme: String, CaseIterable {
    case light, dark, system
}

enum DockIcon: String, CaseIterable {
    case whileWindowOpen, always
}

/// Appearance and placement settings. Unlike keepAwake and the battery floor
/// these change only how the app looks, never what it does to the Mac.
enum Preferences {

    private enum Key {
        static let theme = "theme"
        static let hideMenuBarIcon = "hideMenuBarIcon"
        static let dockIcon = "dockIcon"
        static let openWindowAtLogin = "openWindowAtLogin"
    }

    static var theme: Theme {
        get { UserDefaults.standard.string(forKey: Key.theme).flatMap(Theme.init) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.theme) }
    }

    /// Stored inverted so that a missing value means "shown".
    static var showMenuBarIcon: Bool {
        get { !UserDefaults.standard.bool(forKey: Key.hideMenuBarIcon) }
        set { UserDefaults.standard.set(!newValue, forKey: Key.hideMenuBarIcon) }
    }

    /// What the user picked. What actually applies is `effectiveDockIcon`.
    static var dockIcon: DockIcon {
        get { UserDefaults.standard.string(forKey: Key.dockIcon).flatMap(DockIcon.init) ?? .whileWindowOpen }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.dockIcon) }
    }

    static var openWindowAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: Key.openWindowAtLogin) }
        set { UserDefaults.standard.set(newValue, forKey: Key.openWindowAtLogin) }
    }

    static var effectiveDockIcon: DockIcon {
        dockIcon(chosen: dockIcon, menuBarIcon: showMenuBarIcon)
    }

    /// With the menu bar icon hidden the Dock icon is the only way back in,
    /// so it is forced on whatever was chosen. Without this rule the app
    /// could end up running with no visible way to reach it.
    static func dockIcon(chosen: DockIcon, menuBarIcon: Bool) -> DockIcon {
        menuBarIcon ? chosen : .always
    }
}
