import AppKit

/// Menu bar icon: the Squidpal statolith mark, loaded from the brand assets
/// bundled in the app's Resources (see `build.sh`, which copies
/// `Support/menubar/*.png`). Three states share the same rings:
///
///   recording → rings + coral dot  (StatusOnColor, coloured, non-template)
///   paused    → rings + two bars    (StatusPaused, template)
///   warning   → rings + dot         (StatusOff, template — "not recording")
///
/// Template images follow the menu bar's light/dark appearance automatically.
/// The coloured recording image carries the coral signal dot.
enum MenuIcon {
    enum State { case recording, paused, warning }

    private static let side: CGFloat = 18   // menu bar point size

    // Only touched from the main thread (SwiftUI label).
    nonisolated(unsafe) private static var cache: [State: NSImage] = [:]

    static func image(_ state: State) -> NSImage {
        if let img = cache[state] { return img }
        let (resource, template, label): (String, Bool, String) = {
            switch state {
            case .recording: return ("StatusOnColor", false, "Squidpal spelar in")
            case .paused:    return ("StatusPaused", true, "Squidpal är pausad")
            case .warning:   return ("StatusOff", true, "Squidpal spelar inte in")
            }
        }()
        let img = load(resource) ?? fallback(state)
        img.isTemplate = template
        img.accessibilityDescription = label
        cache[state] = img
        return img
    }

    /// Load a bundled PNG as an 18×18 image with @1x and @2x representations.
    private static func load(_ name: String) -> NSImage? {
        let img = NSImage(size: NSSize(width: side, height: side))
        var added = false
        for suffix in ["", "@2x"] {
            if let url = Bundle.main.url(forResource: name + suffix, withExtension: "png"),
               let rep = NSImageRep(contentsOf: url) {
                img.addRepresentation(rep)
                added = true
            }
        }
        return added ? img : nil
    }

    /// If the resources are missing (e.g. running unbundled), draw a minimal
    /// placeholder so the menu bar is never blank.
    private static func fallback(_ state: State) -> NSImage {
        let coral = NSColor(srgbRed: 0xbf / 255, green: 0x3b / 255, blue: 0x1d / 255, alpha: 1)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            (state == .recording ? coral : NSColor.black).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            ring.lineWidth = 1.5
            ring.stroke()
            if state == .recording {
                coral.setFill()
                let d: CGFloat = 5
                NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d, width: d, height: d)).fill()
            }
            return true
        }
    }
}
