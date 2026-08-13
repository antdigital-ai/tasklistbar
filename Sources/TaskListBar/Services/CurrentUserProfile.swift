import AppKit
import Collaboration
import Foundation

enum CurrentUserProfile {
    private static let thumbnailSide: CGFloat = 64
    private static var cachedImage: NSImage?
    private static var didLoadImage = false

    static var displayName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    static var shortName: String { NSUserName() }

    static var image: NSImage? {
        if didLoadImage { return cachedImage }
        didLoadImage = true
        let name = NSUserName()
        let authorities = [CBIdentityAuthority.local(), CBIdentityAuthority.default()]
        for authority in authorities {
            if let identity = CBIdentity(name: name, authority: authority),
               let raw = identity.image,
               raw.size.width > 1 {
                let thumb = circularThumbnail(from: raw, side: thumbnailSide)
                cachedImage = thumb
                return thumb
            }
        }
        return nil
    }

    static var initials: String {
        let name = displayName
        let parts = name.split { $0.isWhitespace || $0 == "·" }.filter { !$0.isEmpty }
        if parts.count >= 2, parts[0].first?.isASCII == true {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        if name.contains(where: { !$0.isASCII && $0.isLetter }) {
            return String(name.suffix(1))
        }
        return String(name.prefix(1)).uppercased()
    }

    static func openAccountSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.users"
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    static func openHomeFolder() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
    }

    static func symbolImage(_ name: String, size: CGFloat = 16) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        return image
    }

    private static func circularThumbnail(from image: NSImage, side: CGFloat) -> NSImage {
        let output = NSImage(size: NSSize(width: side, height: side))
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(origin: .zero, size: output.size)
        NSBezierPath(ovalIn: rect).addClip()
        let src = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect, from: src, operation: .copy, fraction: 1, respectFlipped: false, hints: [
            .interpolation: NSImageInterpolation.high
        ])
        output.unlockFocus()
        return output
    }
}
