import Foundation

// Runs with ./test.sh — no root, no machine state, nothing installed.
// Covers the two things that would actually hurt if they were wrong: the
// protocol parser (the only untrusted input the root helper accepts) and the
// arm predicate (the entire safety argument).

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok   \(label)")
    } else {
        print("FAIL \(label)")
        failures += 1
    }
}

// MARK: - Protocol: only three verbs, strictly shaped

check(Wire.Request.parse("DISARM") != nil, "DISARM accepted")
check(Wire.Request.parse("STATUS") != nil, "STATUS accepted")
if case .arm(let external, let floor)? = Wire.Request.parse("ARM 2 20") {
    check(external == 2 && floor == 20, "ARM 2 20 parsed")
} else {
    check(false, "ARM 2 20 parsed")
}

for bad in ["ARM", "ARM 1", "ARM 1 2 3", "ARM -1 0", "ARM 99 0", "ARM 1 99", "ARM x 0",
            "arm 1 0", "DISARM now", "", "   ", "ARM 1 0; rm -rf /",
            "PMSET -a disablesleep 1", "ARM 1 0\u{0}"] {
    check(Wire.Request.parse(bad) == nil, "rejected: \(bad.isEmpty ? "<empty>" : bad)")
}
for request in [Wire.Request.disarm, .status, .arm(external: 3, batteryFloor: 20)] {
    check(Wire.Request.parse(request.line) != nil, "round trip: \(request.line)")
    check(request.line.utf8.count <= Wire.maxLineBytes, "within line limit: \(request.line)")
}

// MARK: - Policy: every path to "armed" and every path away from it

let grace: TimeInterval = 5

func sensors(displays: Presence = .present,
             lidClosed: Bool = true,
             onAC: Bool = false,
             battery: Int? = 80,
             thermal: Bool = false,
             console: uid_t? = 501) -> SensorSnapshot {
    SensorSnapshot(displays: displays, displayCount: displays == .present ? 1 : 0,
                   lidClosed: lidClosed, onAC: onAC, battery: battery,
                   thermalDanger: thermal, consoleUID: console)
}

func grant(uid: uid_t = 501, renewed: TimeInterval = 1, started: TimeInterval = 60,
           external: Int = 1, floor: Int = 0) -> GrantView {
    GrantView(uid: uid, sinceRenewed: renewed, sinceStarted: started,
              external: external, batteryFloor: floor)
}

func decide(_ g: GrantView?, _ s: SensorSnapshot, badFor: TimeInterval? = nil) -> (Bool, String) {
    Policy.decide(grant: g, sensors: s, displayBadFor: badFor, displayGrace: grace)
}

// The one and only way to be armed.
check(decide(grant(), sensors()).0, "armed: fresh grant, monitor present, console user")

// Fail-closed paths.
check(!decide(nil, sensors()).0, "safe: no grant at all")
check(!decide(grant(renewed: Wire.heartbeatTimeout + 1), sensors()).0,
      "safe: heartbeat stale (app crashed, killed, or logged out)")
check(!decide(grant(started: Wire.sessionCap + 1), sensors()).0,
      "safe: session cap reached")
check(!decide(grant(), sensors(console: nil)).0,
      "safe: no console user (login window / FileVault prompt)")
check(!decide(grant(uid: 501), sensors(console: 502)).0,
      "safe: different console user (fast user switching)")
check(!decide(grant(external: 0), sensors()).0,
      "safe: app reports no external display")
check(!decide(grant(), sensors(displays: .absent), badFor: grace + 1).0,
      "safe: helper confirms no external display")
check(!decide(grant(), sensors(displays: .unknown), badFor: grace + 1).0,
      "safe: helper cannot verify the display (private API stopped matching)")
check(!decide(grant(), sensors(thermal: true)).0, "safe: thermal warning")
check(!decide(grant(floor: 20), sensors(onAC: false, battery: 19)).0,
      "safe: below the battery floor on battery")

// Grace window: a lid-close tears the display list down and rebuilds it, and
// that must not read as "monitor unplugged".
check(decide(grant(), sensors(displays: .absent), badFor: 1).0,
      "armed: brief bad display reading is tolerated inside the grace window")
check(!decide(grant(), sensors(displays: .absent), badFor: grace + 0.1).0,
      "safe: bad display reading past the grace window is believed")

// Battery floor is opt-in and must not fire when it is off or on AC.
check(decide(grant(floor: 0), sensors(battery: 3)).0, "armed: floor off, battery ignored")
check(decide(grant(floor: 20), sensors(onAC: true, battery: 5)).0,
      "armed: below floor but on AC")
check(decide(grant(floor: 20), sensors(battery: nil)).0,
      "armed: floor set but battery level unreadable")

// Lid state alone decides nothing — it is the monitor that matters.
check(decide(grant(), sensors(lidClosed: false)).0, "armed: lid open is fine")

// MARK: - DisplayPolicy: turning the built-in panel off is the dangerous
// direction, so every gate on it is tested, and so is the rule that the safe
// direction is never gated.

func displays(builtinActive: Bool = true,
              externalActive: Int = 1,
              physicalConfirmed: Bool = true,
              lidClosed: Bool = false,
              available: Bool = true,
              failures: Int = 0) -> DisplaySnapshot {
    DisplaySnapshot(builtinActive: builtinActive, externalActive: externalActive,
                    physicalExternalConfirmed: physicalConfirmed, lidClosed: lidClosed,
                    mechanismAvailable: available, disableFailures: failures)
}

func act(_ intent: Bool, _ d: DisplaySnapshot) -> DisplayAction {
    DisplayPolicy.decide(externalOnly: intent, d).0
}

// The one way to turn it off.
check(act(true, displays()) == .disable,
      "disable: asked for, monitor present and confirmed, lid open")

// Every gate on the dangerous direction.
check(act(false, displays()) == .none, "no-op: not asked for, built-in already on")
check(act(true, displays(externalActive: 0)) == .none, "refuse: no external display")
check(act(true, displays(physicalConfirmed: false)) == .none,
      "refuse: external unconfirmed by the helper (Sidecar/AirPlay)")
check(act(true, displays(available: false)) == .none, "refuse: private API missing")
check(act(true, displays(failures: DisplayPolicy.maxDisableFailures)) == .none,
      "refuse: too many consecutive failures")
check(act(true, displays(lidClosed: true)) == .none, "refuse: lid closed")

// The safe direction, which must never be gated by anything.
check(act(false, displays(builtinActive: false)) == .enable, "restore: user turned it off")
check(act(true, displays(builtinActive: false, externalActive: 0)) == .enable,
      "restore: external display disappeared")
check(act(true, displays(builtinActive: false, physicalConfirmed: false)) == .enable,
      "restore: external no longer confirmed")
check(act(true, displays(builtinActive: false, available: false)) == .enable,
      "restore: private API vanished under us")
check(act(false, displays(builtinActive: false, failures: 99)) == .enable,
      "restore: the disable-failure latch must never block a restore")
check(act(true, displays(builtinActive: false)) == .none,
      "stay off: still asked for, monitor still there")
check(act(true, displays(failures: 99)) == .none,
      "latch only ever applies while the built-in is still on")

// THE RULE: lid open with no external display means the built-in comes on,
// whatever else is true. Each of these would be blocked by some other check if
// the rule were not evaluated first.
check(act(true, displays(builtinActive: false, externalActive: 0)) == .enable,
      "rule: lid open, no external, setting still on -> enable")
check(act(true, displays(builtinActive: false, externalActive: 0,
                         failures: 99)) == .enable,
      "rule: beats the failure latch")
check(act(true, displays(builtinActive: false, externalActive: 0,
                         available: false)) == .enable,
      "rule: still tries even if the private API looks unavailable")
check(act(true, displays(builtinActive: false, externalActive: 0,
                         physicalConfirmed: true)) == .enable,
      "rule: a stale 'external confirmed' cannot suppress it")
check(act(false, displays(builtinActive: false, externalActive: 0)) == .enable,
      "rule: same with the setting off")

// Lid closed is the clamshell feature's territory: do nothing either way.
check(act(true, displays(builtinActive: false, lidClosed: true)) == .none,
      "lid closed: no attempt to light a panel inside a shut lid")
check(act(false, displays(builtinActive: false, lidClosed: true)) == .none,
      "lid closed: no enable attempt either")

// MARK: - DisplayArrangement: where the monitor goes in the scene. Cosmetic,
// but it is what the window is built around, so each Displays-pane layout is
// pinned down. Coordinates are CoreGraphics global space: y grows downward.

let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)

func edge(_ external: CGRect) -> DisplayLayout.Edge? {
    if case .beside(let edge, _) = DisplayArrangement.layout(of: external, beside: laptop) { return edge }
    return nil
}
func edgeOf(_ layout: DisplayLayout?) -> DisplayLayout.Edge? {
    if case .beside(let edge, _)? = layout { return edge }
    return nil
}
func offset(_ external: CGRect) -> Double? {
    if case .beside(_, let offset) = DisplayArrangement.layout(of: external, beside: laptop) { return offset }
    return nil
}

check(edge(CGRect(x: 1512, y: -200, width: 2560, height: 1440)) == .right, "layout: monitor to the right")
check(edge(CGRect(x: -2560, y: -200, width: 2560, height: 1440)) == .left, "layout: monitor to the left")
check(edge(CGRect(x: -524, y: -1440, width: 2560, height: 1440)) == .above, "layout: monitor above")
check(edge(CGRect(x: -524, y: 982, width: 2560, height: 1440)) == .below, "layout: monitor below")
check(edge(CGRect(x: 1400, y: -1440, width: 2560, height: 1440)) == .above,
      "layout: a big monitor overhanging one corner is still above")
check(edge(CGRect(x: 1512, y: -982, width: 1512, height: 982)) == .right,
      "layout: an exact diagonal counts as side by side")
check(abs((offset(CGRect(x: -524, y: -1440, width: 2560, height: 1440)) ?? 99)) < 0.001,
      "layout: centred above gives offset 0")
check((offset(CGRect(x: 1512, y: -1000, width: 1920, height: 1080)) ?? 0) < 0,
      "layout: monitor raised to the right gives a negative offset")

let monitor = ObservedDisplay(key: "1-2-3", name: "Test Monitor",
                              sizeMillimetres: CGSize(width: 600, height: 340),
                              bounds: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                              asleep: false, mirrored: false)
let t0 = Date(timeIntervalSince1970: 1_000_000)

let seen = DisplayArrangement.externals(observed: [monitor], builtinBounds: laptop, memory: [:], now: t0)
check(edgeOf(seen.externals.first?.layout) == .right, "externals: layout read while both are on")
check(seen.memory["1-2-3"]?.layout == seen.externals.first?.layout, "externals: layout remembered")

// Lid shut or built-in turned off: its position can't be read, so keep the old one.
let shut = DisplayArrangement.externals(observed: [monitor], builtinBounds: nil, memory: seen.memory,
                                        now: t0.addingTimeInterval(60))
check(edgeOf(shut.externals.first?.layout) == .right, "externals: remembered layout used while the built-in is off")
check(DisplayArrangement.externals(observed: [monitor], builtinBounds: nil, memory: [:], now: t0)
        .externals.first?.layout == nil, "externals: never seen beside the built-in means no layout")

var mirrored = monitor
mirrored.mirrored = true
check(DisplayArrangement.externals(observed: [mirrored], builtinBounds: laptop, memory: [:], now: t0)
        .externals.first?.layout == .mirrored, "externals: mirroring wins over position")

var sleeping = monitor
sleeping.asleep = true
check(DisplayArrangement.externals(observed: [sleeping], builtinBounds: laptop, memory: [:], now: t0)
        .externals.first?.connection == .asleep, "externals: a sleeping monitor is still connected")

// Unplugged: the last one seen comes back as a ghost, and only then.
let gone = DisplayArrangement.externals(observed: [], builtinBounds: laptop, memory: seen.memory,
                                        now: t0.addingTimeInterval(120))
check(gone.externals.count == 1 && gone.externals.first?.connection == .disconnected,
      "externals: unplugged monitor kept as a disconnected outline")
check(edgeOf(gone.externals.first?.layout) == .right, "externals: the outline stays where it was")
check(seen.externals.allSatisfy { $0.connection != .disconnected },
      "externals: no outline while a monitor is connected")
check(DisplayArrangement.externals(observed: [], builtinBounds: laptop, memory: [:], now: t0)
        .externals.isEmpty, "externals: nothing ever seen means nothing shown")

var older = seen.memory["1-2-3"]!
older.name = "Old Monitor"
older.lastSeen = t0.addingTimeInterval(-86_400)
let two = seen.memory.merging(["9-9-9": older]) { a, _ in a }
check(DisplayArrangement.externals(observed: [], builtinBounds: nil, memory: two, now: t0)
        .externals.first?.key == "1-2-3", "externals: the ghost is the most recently seen monitor")

// The heartbeat must not rewrite the defaults when nothing changed.
let again = DisplayArrangement.externals(observed: [monitor], builtinBounds: laptop, memory: seen.memory,
                                         now: t0.addingTimeInterval(20))
check(again.memory == seen.memory, "memory: unchanged display is not rewritten on a heartbeat")
let later = DisplayArrangement.externals(observed: [monitor], builtinBounds: laptop, memory: seen.memory,
                                         now: t0.addingTimeInterval(DisplayArrangement.lastSeenResolution + 1))
check(later.memory != seen.memory, "memory: timestamp refreshed once the resolution has passed")

var many: [String: RememberedDisplay] = [:]
for i in 0..<(DisplayArrangement.memoryLimit + 3) {
    var record = older
    record.lastSeen = t0.addingTimeInterval(Double(i))
    many["k\(i)"] = record
}
let pruned = DisplayArrangement.externals(observed: [], builtinBounds: nil, memory: many, now: t0).memory
check(pruned.count == DisplayArrangement.memoryLimit && pruned["k0"] == nil,
      "memory: capped, oldest dropped first")

// MARK: - DeskPlacement: the arrangement as furniture.

let right = DeskPlacement.placing(.beside(.right, offset: 0), monitorWidth: 0.48)
let left = DeskPlacement.placing(.beside(.left, offset: 0), monitorWidth: 0.48)
let above = DeskPlacement.placing(.beside(.above, offset: 0), monitorWidth: 0.48)
check(right.monitor.x > right.laptop.x && !right.stacked, "desk: right puts the monitor right of the laptop")
check(left.monitor.x < left.laptop.x && left.monitor.x == -right.monitor.x, "desk: left mirrors right")
check(above.stacked && above.monitor.z < above.laptop.z && above.stand > right.stand,
      "desk: above stands the monitor behind the laptop, raised")
check(DeskPlacement.placing(.beside(.below, offset: 0), monitorWidth: 0.48) == above,
      "desk: below is drawn like above")
check(DeskPlacement.placing(nil, monitorWidth: 0.48) == right, "desk: never-seen layout defaults to the right")
check(DeskPlacement.placing(.mirrored, monitorWidth: 0.48) == right, "desk: mirrored stands side by side")
check(abs(DeskPlacement.placing(.beside(.above, offset: 9), monitorWidth: 0.48).monitor.x
          - 0.5 * DeskPlacement.laptopWidth) < 0.0001, "desk: a large offset is clamped")
let huge = DeskPlacement.placing(.beside(.right, offset: 0), monitorWidth: 1.2)
check(huge.monitor.x + DeskPlacement.maxMonitorWidth / 2 <= 0.65 + 0.0001,
      "desk: an ultra-wide monitor still fits on the desk")
check(DeskPlacement.placing(.beside(.right, offset: 0), monitorWidth: 0) ==
      DeskPlacement.placing(.beside(.right, offset: 0), monitorWidth: DeskPlacement.defaultMonitorWidth),
      "desk: unknown monitor size uses the default")

// MARK: - The spoken summary VoiceOver reads for the scene.

var described = DeviceState.initial
described.externals = seen.externals
check(described.spokenSummary == "MacBook lid open, built-in display on. Test Monitor on, on the right.",
      "summary: both on, side by side")
described.lidClosed = true
described.lidClosedMode = .active
check(described.spokenSummary.hasPrefix("MacBook lid closed, staying awake."), "summary: clamshell, awake")
check(DeviceState.initial.spokenSummary.hasSuffix("No external display."), "summary: nothing connected")

// MARK: - Preferences: the app must never become unreachable.

check(Preferences.dockIcon(chosen: .whileWindowOpen, menuBarIcon: false) == .always,
      "dock: hiding the menu bar icon forces the Dock icon on")
check(Preferences.dockIcon(chosen: .always, menuBarIcon: false) == .always, "dock: always stays always")
check(Preferences.dockIcon(chosen: .whileWindowOpen, menuBarIcon: true) == .whileWindowOpen,
      "dock: with the menu bar icon shown, the choice is honoured")

print("")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
