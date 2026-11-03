import CoreGraphics
import Foundation

/// Everything the menu (and later the window and popover) shows, as one value.
///
/// It describes what macOS reports, never what was asked for. A toggle that
/// failed therefore cannot be drawn as having worked: the built-in is "off"
/// here only once it has actually left the active display list.
struct DeviceState: Equatable {
    var lidClosed: Bool
    var builtinScreen: ScreenState
    /// Connected externals, or — only when none is connected — the one seen
    /// most recently, marked disconnected, so the UI can leave its outline.
    var externals: [ExternalDisplay]
    /// Why the built-in is in its current state when the app had a say in it.
    var builtinNote: String
    var lidClosedMode: LidClosedMode
    var batteryPercent: Int?
    var onAC: Bool

    static let initial = DeviceState(lidClosed: false, builtinScreen: .on, externals: [],
                                     builtinNote: "", lidClosedMode: .off,
                                     batteryPercent: nil, onAC: false)

    /// The external the scene draws: the first connected one, else the
    /// remembered outline, else none.
    var shownExternal: ExternalDisplay? {
        externals.first { $0.connection != .disconnected } ?? externals.first
    }

    /// What VoiceOver reads for the 3D scene, which is otherwise a picture.
    var spokenSummary: String {
        var parts: [String] = []
        if lidClosed {
            var lid = "MacBook lid closed"
            if case .active = lidClosedMode { lid += ", staying awake" }
            parts.append(lid)
        } else {
            let screen: String
            switch builtinScreen {
            case .on: screen = "on"
            case .off: screen = "off"
            case .asleep: screen = "asleep"
            }
            parts.append("MacBook lid open, built-in display \(screen)")
        }
        if let external = shownExternal {
            let connection: String
            switch external.connection {
            case .on: connection = "on"
            case .asleep: connection = "asleep"
            case .disconnected: connection = "disconnected"
            }
            var text = "\(external.name) \(connection)"
            if let layout = external.layout { text += ", \(layout.summary)" }
            parts.append(text)
        } else {
            parts.append("No external display")
        }
        return parts.joined(separator: ". ") + "."
    }
}

/// Where the laptop and monitor stand on the desk, in metres: the desk top
/// is y = 0, x runs right and z runs toward the viewer.
struct DeskPlacement: Equatable {
    var laptop: SIMD3<Float>
    var monitor: SIMD3<Float>
    /// The monitor's stand height. Taller when stacked, so its screen clears
    /// the open lid in front of it.
    var stand: Float
    var stacked: Bool

    static let laptopWidth: Float = 0.31
    static let gap: Float = 0.08
    /// Used when the monitor does not report a physical size.
    static let defaultMonitorWidth: Float = 0.53
    /// Wider monitors are drawn at this width so the desk still holds both.
    static let maxMonitorWidth: Float = 0.85

    static func placing(_ layout: DisplayLayout?, monitorWidth: Float) -> DeskPlacement {
        switch layout {
        case .beside(.above, let offset)?, .beside(.below, let offset)?:
            // Below is drawn like above: nobody's desk has the monitor under the laptop.
            let shift = Float(max(-0.5, min(0.5, offset))) * laptopWidth
            return DeskPlacement(laptop: [0, 0, 0.12], monitor: [shift, 0, -0.16],
                                 stand: 0.25, stacked: true)
        default:
            // Right, left, mirrored, and never-seen all stand side by side.
            let width = monitorWidth > 0 ? min(max(monitorWidth, 0.3), maxMonitorWidth) : defaultMonitorWidth
            let total = laptopWidth + gap + width
            var laptopX = -total / 2 + laptopWidth / 2
            var monitorX = total / 2 - width / 2
            if case .beside(.left, _)? = layout {
                laptopX = -laptopX
                monitorX = -monitorX
            }
            return DeskPlacement(laptop: [laptopX, 0, 0.1], monitor: [monitorX, 0, -0.12],
                                 stand: 0.12, stacked: false)
        }
    }
}

enum ScreenState: Equatable {
    case on
    case off
    case asleep
}

/// The helper's side of things: whether the Mac will stay awake when the lid shuts.
enum LidClosedMode: Equatable {
    case helperMissing
    case off
    case active
    case refused(String)
}

struct ExternalDisplay: Equatable {
    enum Connection: Equatable {
        case on
        case asleep
        case disconnected
    }

    var key: String
    var name: String
    var sizeMillimetres: CGSize
    var connection: Connection
    /// nil until the display has been seen alongside the built-in at least once.
    var layout: DisplayLayout?
}

/// Where an external display sits relative to the built-in, as arranged in
/// System Settings → Displays.
enum DisplayLayout: Equatable, Codable {
    enum Edge: String, Codable {
        case left, right, above, below
    }

    /// `offset` is how far the external's centre sits from the built-in's,
    /// along the shared edge, as a fraction of the built-in's length on that
    /// axis. 0 is centred; positive is further right (above/below) or further
    /// down (left/right).
    case beside(Edge, offset: Double)
    case mirrored

    var summary: String {
        switch self {
        case .beside(.left, _): return "on the left"
        case .beside(.right, _): return "on the right"
        case .beside(.above, _): return "above"
        case .beside(.below, _): return "below"
        case .mirrored: return "mirrored"
        }
    }
}

/// What the app remembers about an external display between sightings.
/// Cosmetic only: nothing that decides power or display state reads it.
struct RememberedDisplay: Codable, Equatable {
    var name: String
    var widthMillimetres: Double
    var heightMillimetres: Double
    var layout: DisplayLayout?
    var lastSeen: Date
}

/// One external display as CoreGraphics reports it right now.
struct ObservedDisplay {
    var key: String
    var name: String
    var sizeMillimetres: CGSize
    /// Global display coordinates: origin at the main display's top-left, y down.
    var bounds: CGRect
    var asleep: Bool
    var mirrored: Bool
}

/// The arrangement logic, as pure functions: no CoreGraphics calls, no
/// defaults, no clock, so every branch runs in ./test.sh.
enum DisplayArrangement {

    /// Displays remembered at most. Old monitors fall off the end.
    static let memoryLimit = 8
    /// An otherwise unchanged record keeps its timestamp this long, so the
    /// heartbeat does not rewrite the defaults every 20 seconds. Only the
    /// order between different displays depends on it.
    static let lastSeenResolution: TimeInterval = 600

    /// Which edge of the built-in the external is against. Distances are
    /// normalised by the two displays' combined half-sizes, so a large
    /// monitor offset to one corner is still classified by the edge it
    /// actually shares. A diagonal tie counts as side by side.
    static func layout(of external: CGRect, beside builtin: CGRect) -> DisplayLayout {
        let dx = external.midX - builtin.midX
        let dy = external.midY - builtin.midY
        let spanX = (external.width + builtin.width) / 2
        let spanY = (external.height + builtin.height) / 2
        guard spanX > 0, spanY > 0, builtin.width > 0, builtin.height > 0 else {
            return .beside(.right, offset: 0)
        }
        if abs(dx) / spanX >= abs(dy) / spanY {
            return .beside(dx < 0 ? .left : .right, offset: Double(dy / builtin.height))
        }
        return .beside(dy < 0 ? .above : .below, offset: Double(dx / builtin.width))
    }

    /// Builds the externals list and the updated memory.
    ///
    /// `builtinBounds` is nil whenever the built-in is not active (lid shut,
    /// or turned off by the app). Its position cannot be read then, so each
    /// external keeps the layout remembered from the last time both were on.
    static func externals(observed: [ObservedDisplay], builtinBounds: CGRect?,
                          memory: [String: RememberedDisplay], now: Date)
        -> (externals: [ExternalDisplay], memory: [String: RememberedDisplay]) {
        var memory = memory
        var externals: [ExternalDisplay] = []

        for display in observed {
            let layout: DisplayLayout?
            if display.mirrored {
                layout = .mirrored
            } else if let builtinBounds {
                layout = self.layout(of: display.bounds, beside: builtinBounds)
            } else {
                layout = memory[display.key]?.layout
            }
            var record = RememberedDisplay(
                name: display.name,
                widthMillimetres: Double(display.sizeMillimetres.width),
                heightMillimetres: Double(display.sizeMillimetres.height),
                layout: layout, lastSeen: now)
            if let previous = memory[display.key],
               now.timeIntervalSince(previous.lastSeen) < lastSeenResolution {
                var unchanged = previous
                unchanged.lastSeen = now
                if unchanged == record { record.lastSeen = previous.lastSeen }
            }
            memory[display.key] = record
            externals.append(ExternalDisplay(key: display.key, name: display.name,
                                             sizeMillimetres: display.sizeMillimetres,
                                             connection: display.asleep ? .asleep : .on,
                                             layout: layout))
        }

        if externals.isEmpty,
           let (key, last) = memory.max(by: { $0.value.lastSeen < $1.value.lastSeen }) {
            externals.append(ExternalDisplay(
                key: key, name: last.name,
                sizeMillimetres: CGSize(width: last.widthMillimetres, height: last.heightMillimetres),
                connection: .disconnected, layout: last.layout))
        }

        if memory.count > memoryLimit {
            let keep = memory.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(memoryLimit)
            memory = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return (externals, memory)
    }
}
