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
    /// Measured rather than estimated from the icon count.
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

        if let band = systemBand(), screen.frame.intersects(band), band.width > 0, band.height > 0 {
            return DockLayout(edge: edge, frame: pill(in: band, edge: edge, tile: tile),
                              tileSize: tile, exact: true, autohides: autohides)
        }
        if let frame = accessibilityFrame(), screen.frame.intersects(frame), frame.width > 0, frame.height > 0 {
            return DockLayout(edge: edge, frame: frame, tileSize: tile, exact: true, autohides: autohides)
        }
        return DockLayout(edge: edge, frame: estimate(edge: edge, tile: tile, screen: screen, prefs: prefs),
                          tileSize: tile, exact: false, autohides: autohides)
    }

    // MARK: from the window server

    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias DockRectFunction = @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>) -> Int32

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let mainConnection = dlsym(skyLight, "SLSMainConnectionID").map { unsafeBitCast($0, to: ConnectionFunction.self) }
    private static let dockRect = dlsym(skyLight, "SLSGetDockRectWithReason").map { unsafeBitCast($0, to: DockRectFunction.self) }

    private typealias CopySpacesFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let copySpaces = dlsym(skyLight, "SLSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopySpacesFunction.self) }

    /// Whether the Space on this screen belongs to an app in full screen —
    /// where macOS tucks the Dock away until the pointer comes for it.
    static func showsFullScreenSpace(_ screen: NSScreen) -> Bool {
        guard let mainConnection, let copySpaces,
              let displays = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return false }
        // One entry per display, or a single one when displays share Spaces.
        let display = displays.first { ($0["Display Identifier"] as? String) == screen.displayUUID }
            ?? (displays.count == 1 ? displays.first : nil)
        guard let current = display?["Current Space"] as? [String: Any] else { return false }
        return (current["type"] as? Int) == fullScreenSpaceType
    }

    private static let fullScreenSpaceType = 4

    /// The strip the Dock keeps for itself, as the window server lays windows
    /// out around it — the same figure window managers such as yabai use. Its
    /// length is the Dock's own, down to the last minimised window, and reading
    /// it needs no permission at all.
    private static func systemBand() -> CGRect? {
        guard let mainConnection, let dockRect else { return nil }
        var rect = CGRect.zero
        var reason: Int32 = 0
        guard dockRect(mainConnection(), &rect, &reason) == 0, rect.width > 0, rect.height > 0 else { return nil }
        // Measured from the top left of the main screen, downward.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The pill inside the strip: as long as the strip, as thick as the icons
    /// make it, floating a few points off the screen edge.
    private static func pill(in band: CGRect, edge: DockEdge, tile: CGFloat) -> CGRect {
        let thickness = tile * 74 / 58
        let depth = edge == .bottom ? band.height : band.width
        let lift = depth > thickness ? min(4, depth - thickness) : 0
        switch edge {
        case .bottom:
            return CGRect(x: band.minX, y: band.minY + lift, width: band.width, height: thickness)
        case .left:
            return CGRect(x: band.minX + lift, y: band.minY, width: thickness, height: band.height)
        case .right:
            return CGRect(x: band.maxX - lift - thickness, y: band.minY, width: thickness, height: band.height)
        }
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

    /// Last resort: count what the Dock shows and lay it out the way the Dock
    /// does. Misses minimised windows. The proportions were measured off a macOS 27 Dock at a
    /// 58 pt tile: icons 62 pt apart, 28 pt more per separator, a 74 pt pill
    /// floating 4 pt off the edge. Close, not exact.
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
        let length = CGFloat(items) * tile * 1.07 + CGFloat(separators) * tile * 0.48 + tile * 0.25

        let band: CGRect
        switch edge {
        case .bottom:
            band = CGRect(x: screen.frame.midX - length / 2, y: screen.frame.minY,
                          width: length, height: screen.visibleFrame.minY - screen.frame.minY)
        case .left:
            band = CGRect(x: screen.frame.minX, y: screen.visibleFrame.midY - length / 2,
                          width: screen.visibleFrame.minX - screen.frame.minX, height: length)
        case .right:
            band = CGRect(x: screen.visibleFrame.maxX, y: screen.visibleFrame.midY - length / 2,
                          width: screen.frame.maxX - screen.visibleFrame.maxX, height: length)
        }
        return pill(in: band, edge: edge, tile: tile)
    }
}

private extension NSScreen {
    /// The identifier the window server files this display's Spaces under.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
