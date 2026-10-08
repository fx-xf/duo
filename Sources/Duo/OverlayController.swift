import AppKit
import MetalKit

/// The full-screen, click-through window the folded desktop is drawn into.
final class OverlayController {
    let renderer: BendRenderer
    private let window: NSWindow
    private let view: MTKView
    private(set) var isVisible = false

    init?(screen: NSScreen) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = BendRenderer(device: device) else { return nil }
        self.renderer = renderer

        let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.presentsWithTransaction = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.delegate = renderer
        if let layer = view.layer as? CAMetalLayer {
            layer.isOpaque = false
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            layer.displaySyncEnabled = true
        }
        self.view = view

        let window = NSWindow(contentRect: screen.frame,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false,
                              screen: screen)
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.sharingType = .none
        window.displaysWhenScreenProfileChanges = true
        self.window = window

        let perMillimetre = Self.pixelsPerMillimetre(of: screen)
        renderer.pixelsPerMillimetre = perMillimetre
        // Notched MacBook panels round their top corners by about 2.2 mm; there is
        // no API for it, so it comes from the physical size and holds in any
        // scaled mode. Older, square-cornered panels get none.
        renderer.cornerRadius = screen.safeAreaInsets.top > 0 ? 2.2 * perMillimetre : 0
    }

    var pixelSize: CGSize {
        let scale = window.screen?.backingScaleFactor ?? 2
        return CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
    }

    var displayID: CGDirectDisplayID {
        window.screen?.displayID ?? CGMainDisplayID()
    }

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    /// Draws first and only then orders the window in, inside the same
    /// transaction, so its first composited frame is already the right one.
    func render(_ params: BendParams) {
        guard renderer.hasFrame else { return }
        renderer.params = params
        view.draw()
        if !isVisible {
            isVisible = true
            window.reassertCollectionBehavior()
            WindowServer.makeSticky(windowID)
            window.orderFrontRegardless()
            if !window.isOnActiveSpace {
                // Last resort: put it on the Space in front, whatever AppKit thinks.
                WindowServer.makeSticky(windowID)
                WindowServer.moveToActiveSpace(windowID)
                Log.engine.error("overlay was not on this Space; moved it, now \(self.window.isOnActiveSpace ? "there" : "still missing", privacy: .public)")
            }
        }
    }

    /// Leaves a transparent frame behind before going away, so whatever the
    /// window shows first next time is invisible. The captured frame is kept:
    /// ScreenCaptureKit only sends a new one when something on screen changes.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        renderer.params.tilt = 0
        view.draw()
        window.orderOut(nil)
    }

    /// Backing pixels per physical millimetre of the panel.
    private static func pixelsPerMillimetre(of screen: NSScreen) -> Double {
        let millimetres = CGDisplayScreenSize(screen.displayID).width
        guard millimetres > 0 else { return 10 }
        return Double(screen.frame.width * screen.backingScaleFactor) / millimetres
    }
}

extension NSWindow {
    /// Sets the collection behaviour afresh. A window kept out of sight can come
    /// back pinned to the one Space it was last shown on, its behaviour still
    /// reading "all Spaces" — the overlay did, after days of sleeps, and folded
    /// only on the first desktop. Ordering it in again doesn't help, and AppKit
    /// skips setting a behaviour that hasn't changed, so clear it first.
    func reassertCollectionBehavior() {
        let behavior = collectionBehavior
        collectionBehavior = []
        collectionBehavior = behavior
    }
}

/// Straight to the window server, for when AppKit's idea of a window's Spaces
/// and the server's part ways — as the overlay's did, on one Space only even
/// right after launch, with "all Spaces" set and set again.
enum WindowServer {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Tags = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt64>, Int32) -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias Move = @convention(c) (Int32, CFArray, UInt64) -> Void

    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection = dlsym(sky, "SLSMainConnectionID").map { unsafeBitCast($0, to: Connection.self) }
    private static let setTags = dlsym(sky, "SLSSetWindowTags").map { unsafeBitCast($0, to: Tags.self) }
    private static let activeSpace = dlsym(sky, "SLSGetActiveSpace").map { unsafeBitCast($0, to: ActiveSpace.self) }
    private static let move = dlsym(sky, "SLSMoveWindowsToManagedSpace").map { unsafeBitCast($0, to: Move.self) }

    /// The tag behind "can join all Spaces".
    private static let stickyTag: UInt64 = 1 << 11

    static func makeSticky(_ window: CGWindowID) {
        guard let connection, let setTags else { return }
        var tags = stickyTag
        _ = setTags(connection(), window, &tags, 64)
    }

    static func moveToActiveSpace(_ window: CGWindowID) {
        guard let connection, let activeSpace, let move else { return }
        let cid = connection()
        move(cid, [NSNumber(value: window)] as CFArray, activeSpace(cid))
    }
}
