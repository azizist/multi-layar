import AppKit
import Combine
import CoreGraphics

/// Reads the displays from macOS and publishes them as one `DeviceState`.
///
/// Read-only: it never changes a display. The controller calls `refresh` after
/// every reconcile, helper reply and sleep/wake, so the state is current
/// whenever something could have moved.
final class DeviceModel: ObservableObject {

    @Published private(set) var state = DeviceState.initial

    private static let memoryKey = "rememberedDisplays"

    func refresh(builtinNote: String, lidClosedMode: LidClosedMode) {
        let builtinActive = InternalDisplay.builtinIsActive()
        let builtinID = builtinActive ? InternalDisplay.builtinID() : nil

        let builtinScreen: ScreenState
        if let builtinID {
            builtinScreen = CGDisplayIsAsleep(builtinID) != 0 ? .asleep : .on
        } else {
            builtinScreen = .off
        }

        let remembered = Self.loadMemory()
        let (externals, memory) = DisplayArrangement.externals(
            observed: Self.observedExternals(memory: remembered),
            builtinBounds: builtinID.map(CGDisplayBounds),
            memory: remembered, now: Date())
        if memory != remembered { Self.saveMemory(memory) }

        let next = DeviceState(lidClosed: InternalDisplay.lidClosed(),
                               builtinScreen: builtinScreen,
                               externals: externals,
                               builtinNote: builtinNote,
                               lidClosedMode: lidClosedMode,
                               batteryPercent: PowerInfo.batteryPercent(),
                               onAC: PowerInfo.onAC())
        // Only publish real changes, so a 20-second heartbeat never redraws a
        // scene that has not moved.
        if next != state { state = next }
    }

    /// Online rather than active, so a sleeping monitor still counts as
    /// connected. Display IDs are never cached: lid transitions renumber them.
    private static func observedExternals(memory: [String: RememberedDisplay]) -> [ObservedDisplay] {
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return (id, screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })

        return InternalDisplay.onlineDisplays()
            .filter { CGDisplayIsBuiltin($0) == 0 }
            .map { id in
                // Two identical monitors without serial numbers share a key;
                // the cost is one remembered position for both.
                let key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
                return ObservedDisplay(
                    key: key,
                    // A sleeping display has no NSScreen, so fall back to the last name seen.
                    name: names[id] ?? memory[key]?.name ?? "External Display",
                    sizeMillimetres: CGDisplayScreenSize(id),
                    bounds: CGDisplayBounds(id),
                    asleep: CGDisplayIsAsleep(id) != 0,
                    mirrored: CGDisplayIsInMirrorSet(id) != 0)
            }
    }

    private static func loadMemory() -> [String: RememberedDisplay] {
        guard let data = UserDefaults.standard.data(forKey: memoryKey),
              let memory = try? JSONDecoder().decode([String: RememberedDisplay].self, from: data)
        else { return [:] }
        return memory
    }

    private static func saveMemory(_ memory: [String: RememberedDisplay]) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        UserDefaults.standard.set(data, forKey: memoryKey)
    }
}
