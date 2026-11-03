import AppKit
import ImageIO

/// Reads each screen's current wallpaper, for the 3D screens to show.
///
/// Only screens that are on need one, and a screen that is on always has an
/// NSScreen, so nothing is remembered across launches. A wallpaper stored in
/// Desktop, Documents or Downloads makes macOS ask for file access the first
/// time; if that is refused the scene uses its fallback image.
@MainActor
final class Wallpaper {

    /// Decoded images by file, so a state change does not decode a 6K HEIC again.
    private var decoded: [URL: CGImage] = [:]

    /// Keyed like `DeviceModel` keys displays, `DeviceModel.builtinKey` for the built-in.
    func current() -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let image = image(for: screen)
            else { continue }
            result[DeviceModel.key(for: id)] = image
        }
        return result
    }

    private func image(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let cached = decoded[url] { return cached }
        let image = Self.thumbnail(of: url) ?? Self.fill(for: screen)
        if let image {
            if decoded.count > 8 { decoded.removeAll() }
            decoded[url] = image
        }
        return image
    }

    /// A thumbnail, not the full image: it only ever covers a few hundred
    /// pixels. Dynamic HEIC wallpapers give their first frame.
    private static func thumbnail(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1024,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A solid-colour desktop keeps its colour in the options, not the file.
    private static func fill(for screen: NSScreen) -> CGImage? {
        guard let color = NSWorkspace.shared.desktopImageOptions(for: screen)?[.fillColor] as? NSColor,
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }
}
