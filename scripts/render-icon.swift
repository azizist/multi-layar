import AppKit
import WebKit

// swift scripts/render-icon.swift <in.svg> <out.png>
//
// Renders an SVG to a 1024×1024 PNG with WebKit, the only renderer on a stock
// Mac that handles the icon's blur filters, clip paths and masks.

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: render-icon.swift <in.svg> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let svg = try String(contentsOfFile: arguments[1], encoding: .utf8)
let output = URL(fileURLWithPath: arguments[2])
let size = 1024.0

final class Renderer: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: size, height: size)
        config.snapshotWidth = NSNumber(value: size)
        webView.takeSnapshot(with: config) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                FileHandle.standardError.write("snapshot failed: \(String(describing: error))\n".data(using: .utf8)!)
                exit(1)
            }
            // The snapshot comes back at the screen's scale; pin it to 1024 px.
            let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
            rep.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            try! pixels.representation(using: .png, properties: [:])!.write(to: output)
            exit(0)
        }
    }
}

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                      styleMask: .borderless, backing: .buffered, defer: false)
let webView = WKWebView(frame: window.contentView!.bounds)
webView.setValue(false, forKey: "drawsBackground")
window.contentView = webView
let renderer = Renderer()
webView.navigationDelegate = renderer
webView.loadHTMLString("<html><body style=\"margin:0;background:transparent\">\(svg)</body></html>", baseURL: nil)
RunLoop.main.run()
