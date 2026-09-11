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

    /// Draws first and only then orders the window in, inside the same
    /// transaction, so its first composited frame is already the right one.
    func render(_ params: BendParams) {
        guard renderer.hasFrame else { return }
        renderer.params = params
        view.draw()
        if !isVisible {
            isVisible = true
            window.orderFrontRegardless()
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
