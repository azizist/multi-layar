import AppKit
import RealityKit

/// What the tabletop is made of. Only plain colours ship; `texture` is the
/// hook for wood, HPL and the like — a tileable image repeated across the top.
enum TableFinish {
    case plain(NSColor)
    case texture(CGImage, tilesPerMetre: Float)
}

/// The desk as a whole: its top and its legs.
struct TableLook {
    var top: TableFinish
    var legs: NSColor

    /// White laminate on white legs, for the light appearance.
    static let light = TableLook(top: .plain(NSColor(white: 0.94, alpha: 1)), legs: NSColor(white: 0.93, alpha: 1))
    /// Dark grey laminate on black legs, for the dark appearance.
    static let dark = TableLook(top: .plain(NSColor(red: 0.40, green: 0.39, blue: 0.37, alpha: 1)),
                                legs: NSColor(white: 0.07, alpha: 1))
}

/// The desk, the laptop and the monitor, built from primitives in code so the
/// app ships no model files. Metres throughout; the tabletop is y = 0.
///
/// `apply` moves it to match a `DeviceState`. It draws only what the state
/// says macOS reported — it has no opinion of its own about any display.
@MainActor
final class DeviceScene {

    let root = Entity()
    let camera = PerspectiveCamera()

    private let laptop = Entity()
    private let hinge = Entity()
    private let builtinScreen: ScreenFace
    private let statusLight: ModelEntity
    private let monitor = Entity()
    private let monitorHead = Entity()
    private let monitorPanel: ModelEntity
    private let monitorScreen: ScreenFace
    private let monitorNeck: ModelEntity
    private var monitorSize = SIMD2<Float>(0, 0)
    private let tableTop: ModelEntity
    private var tableLegs: [ModelEntity] = []
    /// Last target per entity, so an unchanged state starts no animation.
    private var targets: [ObjectIdentifier: Transform] = [:]

    private static let lidHeight: Float = 0.21
    private static let hingePosition = SIMD3<Float>(0, 0.012, -0.11)
    private static let animation: TimeInterval = 0.8

    init(table look: TableLook = .light) {
        builtinScreen = ScreenFace(ModelEntity(mesh: .generatePlane(width: 0.29, height: 0.185)))
        monitorScreen = ScreenFace(ModelEntity())
        monitorPanel = ModelEntity(mesh: .generateBox(size: 0.01), materials: [Self.bezel])
        monitorNeck = ModelEntity(mesh: .generateBox(width: 0.05, height: 1, depth: 0.02),
                                  materials: [Self.stand])
        statusLight = ModelEntity(mesh: .generateBox(width: 0.014, height: 0.0025, depth: 0.002),
                                  materials: [UnlitMaterial(color: NSColor(red: 0.2, green: 0.85, blue: 0.4, alpha: 1))])

        tableTop = ModelEntity(mesh: .generateBox(size: Self.tableSize, cornerRadius: 0.004))
        root.addChild(makeTable())
        setTable(look)
        buildLaptop()
        buildMonitor()

        let sun = DirectionalLight()
        sun.light.intensity = 3000
        sun.look(at: .zero, from: [0.6, 1.2, 1.0], relativeTo: nil)
        root.addChild(sun)

        camera.camera.fieldOfViewInDegrees = 35
        root.addChild(camera)
    }

    // MARK: - Applying state

    /// Moves the scene to `state`. Returns how long the change animates for:
    /// 0 when nothing moved, so the renderer can draw a single frame.
    func apply(_ state: DeviceState, wallpapers: [String: CGImage], animated: Bool) -> TimeInterval {
        let duration = animated ? Self.animation : 0
        var moved = false

        let external = state.shownExternal
        let size = external.map {
            SIMD2<Float>(Float($0.sizeMillimetres.width / 1000), Float($0.sizeMillimetres.height / 1000))
        } ?? .zero
        let placement = DeskPlacement.placing(external?.layout, monitorWidth: size.x)

        moved = move(laptop, to: Transform(translation: placement.laptop), duration) || moved
        let lidAngle: Float = state.lidClosed ? 1.56 : -0.22
        moved = move(hinge, to: Transform(rotation: simd_quatf(angle: lidAngle, axis: [1, 0, 0]),
                                          translation: Self.hingePosition), duration) || moved

        let fallback = Self.fallbackWallpaper
        builtinScreen.show(state.builtinScreen, image: wallpapers[DeviceModel.builtinKey] ?? fallback)
        statusLight.isEnabled = state.lidClosed && state.lidClosedMode == .active

        if let external {
            monitor.isEnabled = true
            resizeMonitor(to: size)
            moved = move(monitor, to: Transform(translation: placement.monitor), duration) || moved
            moved = move(monitorHead, to: Transform(translation: [0, placement.stand, 0]), duration) || moved
            moved = move(monitorNeck, to: Transform(scale: [1, placement.stand, 1],
                                                    translation: [0, placement.stand / 2, -0.02]), duration) || moved
            switch external.connection {
            case .on: monitorScreen.show(.on, image: wallpapers[external.key] ?? fallback)
            case .asleep: monitorScreen.show(.asleep, image: fallback)
            case .disconnected: monitorScreen.show(.off, image: fallback)
            }
            // An unplugged monitor stays as a faint outline where it stood.
            if external.connection == .disconnected {
                monitor.components.set(OpacityComponent(opacity: 0.22))
            } else {
                monitor.components.remove(OpacityComponent.self)
            }
        } else {
            monitor.isEnabled = false
        }

        // Framed on the tabletop; pulled back a little when stacked.
        let framing = Entity()
        if placement.stacked {
            framing.look(at: [0, 0.24, 0], from: [0.06, 0.74, 1.55], relativeTo: nil)
        } else {
            framing.look(at: [0, 0.16, 0], from: [0.1, 0.6, 1.4], relativeTo: nil)
        }
        moved = move(camera, to: framing.transform, duration) || moved

        return moved ? duration : 0
    }

    private func move(_ entity: Entity, to target: Transform, _ duration: TimeInterval) -> Bool {
        let key = ObjectIdentifier(entity)
        if let last = targets[key], Self.same(last, target) { return false }
        targets[key] = target
        if duration > 0 {
            entity.move(to: target, relativeTo: entity.parent, duration: duration, timingFunction: .easeInOut)
        } else {
            entity.transform = target
        }
        return true
    }

    private static func same(_ a: Transform, _ b: Transform) -> Bool {
        simd_distance(a.translation, b.translation) < 1e-5
            && simd_distance(a.scale, b.scale) < 1e-5
            && abs(simd_dot(a.rotation.vector, b.rotation.vector)) > 1 - 1e-6
    }

    // MARK: - Models

    private static let aluminium = SimpleMaterial(color: NSColor(red: 0.36, green: 0.37, blue: 0.39, alpha: 1),
                                                  roughness: 0.45, isMetallic: true)
    private static let stand = SimpleMaterial(color: NSColor(white: 0.42, alpha: 1), roughness: 0.5, isMetallic: true)
    private static let bezel = SimpleMaterial(color: NSColor(white: 0.12, alpha: 1), roughness: 0.6, isMetallic: false)

    private func buildLaptop() {
        let base = ModelEntity(mesh: .generateBox(width: 0.31, height: 0.012, depth: 0.22, cornerRadius: 0.006),
                               materials: [Self.aluminium])
        base.position = [0, 0.006, 0]
        let keyboard = ModelEntity(mesh: .generateBox(width: 0.27, height: 0.001, depth: 0.1),
                                   materials: [SimpleMaterial(color: .black, roughness: 0.8, isMetallic: false)])
        keyboard.position = [0, 0.0125, -0.03]
        statusLight.position = [0.13, 0.006, 0.1105]
        laptop.addChild(base)
        laptop.addChild(keyboard)
        laptop.addChild(statusLight)

        let lid = ModelEntity(mesh: .generateBox(width: 0.31, height: Self.lidHeight, depth: 0.006, cornerRadius: 0.005),
                              materials: [Self.aluminium])
        lid.position = [0, Self.lidHeight / 2, 0]
        builtinScreen.entity.position = [0, Self.lidHeight / 2, 0.0035]
        hinge.addChild(lid)
        hinge.addChild(builtinScreen.entity)
        laptop.addChild(hinge)
        root.addChild(laptop)
    }

    private func buildMonitor() {
        let foot = ModelEntity(mesh: .generateBox(width: 0.2, height: 0.01, depth: 0.15, cornerRadius: 0.004),
                               materials: [Self.stand])
        foot.position = [0, 0.005, 0]
        monitor.addChild(foot)
        monitor.addChild(monitorNeck)
        monitorHead.addChild(monitorPanel)
        monitorHead.addChild(monitorScreen.entity)
        monitor.addChild(monitorHead)
        root.addChild(monitor)
    }

    /// Regenerated only when a different monitor shows up.
    private func resizeMonitor(to reported: SIMD2<Float>) {
        var size = reported
        if size.x <= 0 || size.y <= 0 {
            size = [DeskPlacement.defaultMonitorWidth, DeskPlacement.defaultMonitorWidth * 9 / 16]
        }
        if size.x > DeskPlacement.maxMonitorWidth {
            size *= DeskPlacement.maxMonitorWidth / size.x
        }
        guard size != monitorSize else { return }
        monitorSize = size
        let bezel: Float = 0.01
        monitorPanel.model?.mesh = .generateBox(width: size.x + bezel * 2, height: size.y + bezel * 2,
                                                depth: 0.02, cornerRadius: 0.006)
        monitorPanel.position = [0, size.y / 2 + bezel, 0]
        monitorScreen.entity.model = ModelComponent(mesh: .generatePlane(width: size.x, height: size.y),
                                                    materials: [UnlitMaterial(color: .black)])
        monitorScreen.entity.position = [0, size.y / 2 + bezel, 0.0105]
        monitorScreen.invalidate()
    }

    static let tableSize = SIMD3<Float>(1.3, 0.025, 0.62)

    /// A plain desk: a laminate top on four round legs with dark feet.
    private func makeTable() -> Entity {
        let table = Entity()
        tableTop.position = [0, -Self.tableSize.y / 2, 0]
        table.addChild(tableTop)

        let legHeight: Float = 0.7, footHeight: Float = 0.012, radius: Float = 0.0175
        let cap = SimpleMaterial(color: NSColor(white: 0.05, alpha: 1), roughness: 0.8, isMetallic: false)
        let inset = SIMD2<Float>(Self.tableSize.x / 2 - 0.05, Self.tableSize.z / 2 - 0.05)
        for (x, z) in [(-inset.x, -inset.y), (inset.x, -inset.y), (-inset.x, inset.y), (inset.x, inset.y)] {
            let tube = ModelEntity(mesh: .generateCylinder(height: legHeight - footHeight, radius: radius))
            tube.position = [x, -Self.tableSize.y - (legHeight - footHeight) / 2, z]
            let foot = ModelEntity(mesh: .generateCylinder(height: footHeight, radius: radius * 0.95),
                                   materials: [cap])
            foot.position = [x, -Self.tableSize.y - legHeight + footHeight / 2, z]
            tableLegs.append(tube)
            table.addChild(tube)
            table.addChild(foot)
        }
        return table
    }

    /// Repaints the desk. Returns nothing to animate: it is a material swap.
    func setTable(_ look: TableLook) {
        var top = PhysicallyBasedMaterial()
        top.roughness = 0.6
        top.metallic = 0.0
        switch look.top {
        case .plain(let color):
            top.baseColor = .init(tint: color)
        case .texture(let image, let tilesPerMetre):
            if let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
                top.baseColor = .init(texture: .init(texture))
                top.textureCoordinateTransform.scale = [Self.tableSize.x * tilesPerMetre,
                                                        Self.tableSize.z * tilesPerMetre]
            }
        }
        tableTop.model?.materials = [top]
        let legs = SimpleMaterial(color: look.legs, roughness: 0.4, isMetallic: false)
        for leg in tableLegs { leg.model?.materials = [legs] }
    }

    // MARK: - Lighting and fallbacks

    /// A soft studio — bright overhead, neutral horizon, dark floor, one broad
    /// key light — generated rather than shipped. Offscreen rendering has no
    /// default image-based light, and without one metal reads as black.
    static func studioEnvironment() -> EnvironmentResource? {
        let width = 512, height = 256
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // CG's origin is bottom-left: y = height is the zenith.
        let sky = [CGColor(gray: 0.95, alpha: 1), CGColor(gray: 0.62, alpha: 1), CGColor(gray: 0.22, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 0.5, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        }
        let key = [CGColor(gray: 1, alpha: 0.9), CGColor(gray: 1, alpha: 0)]
        if let glow = CGGradient(colorsSpace: space, colors: key as CFArray, locations: [0, 1]) {
            let centre = CGPoint(x: Double(width) * 0.62, y: Double(height) * 0.78)
            context.drawRadialGradient(glow, startCenter: centre, startRadius: 0,
                                       endCenter: centre, endRadius: 70, options: [])
        }
        guard let image = context.makeImage() else { return nil }
        return try? EnvironmentResource(equirectangular: image, withName: "studio")
    }

    /// Shown on a lit screen whose wallpaper could not be read.
    static let fallbackWallpaper: CGImage = {
        let context = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(red: 0.12, green: 0.31, blue: 0.55, alpha: 1),
                      CGColor(red: 0.65, green: 0.78, blue: 0.94, alpha: 1)]
        let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 36), end: CGPoint(x: 64, y: 0), options: [])
        return context.makeImage()!
    }()
}

/// One screen surface. Rebuilds its texture only when the wallpaper image
/// actually changes, and swaps material only when on/off changes.
@MainActor
private final class ScreenFace {
    let entity: ModelEntity
    private var image: CGImage?
    private var lit: RealityKit.Material = UnlitMaterial(color: .black)
    private var shown: ScreenState?

    init(_ entity: ModelEntity) {
        self.entity = entity
    }

    /// Call after replacing the entity's model, so the next `show` repaints it.
    func invalidate() {
        shown = nil
    }

    func show(_ state: ScreenState, image newImage: CGImage) {
        if state == .on, newImage !== image {
            image = newImage
            if let texture = try? TextureResource(image: newImage, options: .init(semantic: .color)) {
                var material = UnlitMaterial()
                material.color = .init(tint: .white, texture: .init(texture))
                lit = material
            }
            shown = nil
        }
        guard state != shown else { return }
        shown = state
        entity.model?.materials = [state == .on ? lit : UnlitMaterial(color: .black)]
    }
}
