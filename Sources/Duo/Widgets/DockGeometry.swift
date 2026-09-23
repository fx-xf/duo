import AppKit
import ApplicationServices

enum DockEdge: Equatable {
    case bottom, left, right
}

struct DockLayout: Equatable {
    var edge: DockEdge
    /// The Dock itself, in screen coordinates.
    var frame: CGRect
    var tileSize: CGFloat
    /// Measured through Accessibility rather than estimated from the icon count.
    var exact: Bool
    var autohides: Bool

    /// Widgets are exactly as thick as the Dock, so they read as more of it.
    var bubbleSize: CGFloat {
        let thickness = edge == .bottom ? frame.height : frame.width
        return min(max(thickness, 32), 128)
    }
}

enum DockProbe {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func measure(on screen: NSScreen) -> DockLayout {
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        let edge: DockEdge
        switch prefs?.string(forKey: "orientation") {
        case "left": edge = .left
        case "right": edge = .right
        default: edge = .bottom
        }
        let storedTile = prefs?.double(forKey: "tilesize") ?? 0
        let tile = CGFloat(storedTile > 0 ? storedTile : 64)
        let autohides = prefs?.bool(forKey: "autohide") ?? false

        if let frame = accessibilityFrame(), screen.frame.intersects(frame), frame.width > 0, frame.height > 0 {
            return DockLayout(edge: edge, frame: frame, tileSize: tile, exact: true, autohides: autohides)
        }
        return DockLayout(edge: edge, frame: estimate(edge: edge, tile: tile, screen: screen, prefs: prefs),
                          tileSize: tile, exact: false, autohides: autohides)
    }

    /// The Dock's own list of icons, as Accessibility sees it.
    private static func accessibilityFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return nil }

        for element in elements {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXListRole as String else { continue }
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size else { continue }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
            // Accessibility measures from the top left of the main screen, downward.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: origin.x, y: mainHeight - origin.y - extent.height, width: extent.width, height: extent.height)
        }
        return nil
    }

    /// Without Accessibility: count what the Dock shows and lay it out the way
    /// the Dock does. The proportions were measured off a macOS 27 Dock at a
    /// 58 pt tile: icons 62 pt apart, 28 pt more per separator, a 67 pt pill
    /// floating 6 pt off the edge. Close, not exact.
    private static func estimate(edge: DockEdge, tile: CGFloat, screen: NSScreen, prefs: UserDefaults?) -> CGRect {
        func bundleIDs(_ key: String) -> [String] {
            (prefs?.array(forKey: key) as? [[String: Any]] ?? [])
                .compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
        }
        let persistent = bundleIDs("persistent-apps")
        let others = (prefs?.array(forKey: "persistent-others") ?? []).count
        let showsRecents = prefs?.object(forKey: "show-recents") as? Bool ?? true
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != "com.apple.finder" && !persistent.contains($0) }
        // Apps running outside the Dock share a section with the recent ones.
        var middle = Set(running)
        if showsRecents { middle.formUnion(bundleIDs("recent-apps").filter { !persistent.contains($0) }) }

        let items = 1 + persistent.count + middle.count + others + 1
        let separators = (middle.isEmpty ? 0 : 1) + 1
        let thickness = tile * 1.155
        let length = CGFloat(items) * tile * 1.07 + CGFloat(separators) * tile * 0.48 + tile * 0.2
        let offEdge: CGFloat = 6

        switch edge {
        case .bottom:
            let band = screen.visibleFrame.minY - screen.frame.minY
            let lift = band > thickness ? min(offEdge, band - thickness) : 0
            return CGRect(x: screen.frame.midX - length / 2, y: screen.frame.minY + lift,
                          width: length, height: thickness)
        case .left:
            let band = screen.visibleFrame.minX - screen.frame.minX
            let lift = band > thickness ? min(offEdge, band - thickness) : 0
            return CGRect(x: screen.frame.minX + lift, y: screen.visibleFrame.midY - length / 2,
                          width: thickness, height: length)
        case .right:
            let band = screen.frame.maxX - screen.visibleFrame.maxX
            let lift = band > thickness ? min(offEdge, band - thickness) : 0
            return CGRect(x: screen.frame.maxX - lift - thickness, y: screen.visibleFrame.midY - length / 2,
                          width: thickness, height: length)
        }
    }
}
