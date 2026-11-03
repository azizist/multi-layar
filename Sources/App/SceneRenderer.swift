import Combine
import CoreGraphics
@preconcurrency import Metal
import RealityKit

/// Renders the `DeviceScene` offscreen and publishes each frame as an image.
///
/// Not a live RealityView: that draws every frame whether or not anything
/// moved, which measured ~40% of a core on an M2 Pro for a still scene,
/// minimized or not. Here frames are produced only while something animates;
/// a still scene costs nothing.
@MainActor
final class SceneRenderer: ObservableObject {

    @Published private(set) var image: CGImage?

    let scene: DeviceScene
    private let renderer: RealityRenderer
    private let device: MTLDevice
    private var texture: MTLTexture?
    private var frameTimer: Timer?
    private var animateUntil = Date.distantPast
    private var lastFrame = Date()
    private var renderInFlight = false
    private var hasState = false
    private var isDark: Bool?

    /// Large windows are drawn at most this many pixels on a side; the
    /// image is scaled up, which a soft 3D scene hides well.
    private static let maxDimension = 3000

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CocoaError(.featureUnsupported)
        }
        self.device = device
        renderer = try RealityRenderer()
        scene = DeviceScene()
        renderer.entities.append(scene.root)
        renderer.activeCamera = scene.camera
        if let studio = DeviceScene.studioEnvironment() {
            renderer.lighting.resource = studio
        }
    }

    /// Follows the window's light or dark appearance: the background behind
    /// the desk, and the desk itself.
    func setAppearance(dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        renderer.cameraSettings.colorBackground = .color(dark ? CGColor(gray: 0.16, alpha: 1)
                                                              : CGColor(gray: 0.87, alpha: 1))
        scene.setTable(dark ? .dark : .light)
        animate(for: 0)
    }

    /// The view's size in pixels. Recreates the target and redraws once.
    func resize(width: Int, height: Int) {
        let scale = min(1, Double(Self.maxDimension) / Double(max(width, height, 1)))
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        guard texture?.width != w || texture?.height != h else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        texture = device.makeTexture(descriptor: descriptor)
        animate(for: 0)
    }

    /// The first state snaps into place; every later one animates.
    func show(_ state: DeviceState, wallpapers: [String: CGImage]) {
        let duration = scene.apply(state, wallpapers: wallpapers, animated: hasState)
        hasState = true
        animate(for: duration)
    }

    /// Runs the frame loop for `duration` plus a settling frame, then stops.
    private func animate(for duration: TimeInterval) {
        animateUntil = max(animateUntil, Date().addingTimeInterval(duration + 0.05))
        guard frameTimer == nil else { return }
        lastFrame = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.renderFrame()
                if Date() > self.animateUntil {
                    timer.invalidate()
                    self.frameTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
        renderFrame()
    }

    private func renderFrame() {
        guard !renderInFlight, let texture else { return }
        let now = Date()
        let delta = now.timeIntervalSince(lastFrame)
        lastFrame = now
        renderInFlight = true
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
            try renderer.updateAndRender(deltaTime: delta, cameraOutput: output, onComplete: { [weak self] _ in
                Task { @MainActor in self?.publish(texture) }
            })
        } catch {
            renderInFlight = false
            NSLog("ClamshellKeeper: scene render failed: \(error)")
        }
    }

    private func publish(_ texture: MTLTexture) {
        renderInFlight = false
        // A resize can land mid-frame; that frame is for the old size.
        guard texture === self.texture else { return }
        let width = texture.width, height = texture.height, rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return }
        image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                        space: space,
                        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                 | CGImageAlphaInfo.premultipliedFirst.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    deinit {
        frameTimer?.invalidate()
    }
}
