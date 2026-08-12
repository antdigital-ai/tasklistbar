import AppKit
import Foundation

/// Shared icon / app metadata cache to avoid repeated NSWorkspace + Bundle hits.
enum AppIconCache {
    private static let lock = NSLock()
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]
    private static var urls: [String: URL] = [:]

    static func icon(forFile path: String, size: CGFloat = 64) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(path)|\(Int(size))"
        if let cached = icons[key] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: size, height: size)
        icons[key] = image
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

        let image = fallback
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: bid)
            ?? NSImage()
        image.size = NSSize(width: size, height: size)
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
}
