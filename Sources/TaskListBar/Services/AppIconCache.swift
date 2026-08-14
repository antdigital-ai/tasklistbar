import AppKit
import Foundation

/// Shared icon / app metadata cache to avoid repeated NSWorkspace + Bundle hits.
enum AppIconCache {
    private static let lock = NSLock()
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]
    private static var urls: [String: URL] = [:]
    private static let rasterScale: CGFloat = 2

    static func icon(forFile path: String, size: CGFloat = 64) -> NSImage {
        let key = "\(path)|\(Int(size))"
        lock.lock()
        if let cached = icons[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let source = NSWorkspace.shared.icon(forFile: path)
        let image = rasterize(source, side: size)

        lock.lock()
        icons[key] = image
        lock.unlock()
        return image
    }

    static func icon(forBundleID bid: String, url: URL?, fallback: NSImage?, size: CGFloat = 64) -> NSImage {
        if let url {
            return icon(forFile: url.path, size: size)
        }
        lock.lock()
        if let cached = icons[bid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let source = fallback
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: bid)
            ?? NSImage()
        let image = rasterize(source, side: size)
        lock.lock()
        icons[bid] = image
        lock.unlock()
        return image
    }

    static func url(forBundleID bid: String) -> URL? {
        lock.lock()
        if let cached = urls[bid] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        if let url {
            lock.lock()
            urls[bid] = url
            lock.unlock()
        }
        return url
    }

    static func displayName(forBundleID bid: String, url: URL?, runningName: String?) -> String {
        if let runningName, !runningName.isEmpty { return runningName }
        lock.lock()
        if let cached = names[bid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved: String = {
            if let url, let bundle = Bundle(url: url) {
                return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
            }
            return bid
        }()

        lock.lock()
        names[bid] = resolved
        lock.unlock()
        return resolved
    }

    static func invalidate(bundleID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let bundleID {
            names.removeValue(forKey: bundleID)
            urls.removeValue(forKey: bundleID)
            icons = icons.filter { !$0.key.hasPrefix(bundleID) }
        } else {
            icons.removeAll(keepingCapacity: true)
            names.removeAll(keepingCapacity: true)
            urls.removeAll(keepingCapacity: true)
        }
    }

    /// NSWorkspace icons are full-size ICNS (often 1024px). Setting `NSImage.size`
    /// only changes the preferred drawing size, so SwiftUI would still upload the
    /// huge bitmap. Rasterize once at the display size.
    private static func rasterize(_ source: NSImage, side: CGFloat) -> NSImage {
        let pointSize = NSSize(width: side, height: side)
        let pixels = max(1, Int((side * rasterScale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            let copy = source.copy() as? NSImage ?? source
            copy.size = pointSize
            return copy
        }
        rep.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .medium
            source.draw(
                in: NSRect(origin: .zero, size: pointSize),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: pointSize)
        output.addRepresentation(rep)
        return output
    }
}
