import AppKit
import CoreVideo
import QuartzCore

/// The colour the Dock is actually painted in, read off the screen.
///
/// The Dock does not use any glass an app can ask for: its material lives in
/// the Dock's own process, tinted by the Liquid Glass slider and by rules of
/// its own. Rather than guess at them, Duo samples the Dock's background — the
/// strips just inside the top and bottom of its pill, clear of the icons — from
/// the frames it already captures for the fold, and paints the widgets in
/// exactly that. Whatever the system does to the Dock, the widgets follow.
final class DockTone: ObservableObject {
    static let shared = DockTone()

    /// Nil until a frame has been sampled (or without Screen Recording).
    @Published private(set) var top: NSColor?
    @Published private(set) var bottom: NSColor?

    private let lock = NSLock()
    private var region: CGRect?
    private var screenHeight: CGFloat = 0
    private var scale: CGFloat = 2
    private var lastSample: CFTimeInterval = 0

    /// Where the Dock is, in screen points, as the shelf last measured it.
    func track(dock frame: CGRect, on screen: NSScreen) {
        lock.lock()
        region = frame
        screenHeight = screen.frame.height
        scale = screen.backingScaleFactor
        lock.unlock()
    }

    /// Called from the capture queue with every frame; samples a few times a second.
    func sample(_ buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard let dock = region, now - lastSample > 0.4 else {
            lock.unlock()
            return
        }
        lastSample = now
        let height = screenHeight
        let scale = self.scale
        lock.unlock()

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let rows = CVPixelBufferGetHeight(buffer)

        // Frames are top-down; keep off the rounded ends and the bright rim.
        let x0 = Int((dock.minX + 26) * scale)
        let x1 = Int((dock.maxX - 26) * scale)
        let topEdge = (height - dock.maxY) * scale
        let bottomEdge = (height - dock.minY) * scale

        func strip(from y0: CGFloat, to y1: CGFloat) -> NSColor? {
            var reds = [UInt8](), greens = [UInt8](), blues = [UInt8]()
            for y in Int(y0)..<Int(y1) where y >= 0 && y < rows {
                for x in stride(from: max(x0, 0), to: min(x1, width), by: 5) {
                    let pixel = base + y * rowBytes + x * 4
                    blues.append(pixel[0])
                    greens.append(pixel[1])
                    reds.append(pixel[2])
                }
            }
            guard reds.count > 20 else { return nil }
            // The median ignores the odd icon corner or running-app dot.
            func median(_ values: [UInt8]) -> CGFloat { CGFloat(values.sorted()[values.count / 2]) / 255 }
            return NSColor(displayP3Red: median(reds), green: median(greens), blue: median(blues), alpha: 1)
        }

        let top = strip(from: topEdge + 3 * scale, to: topEdge + 6 * scale)
        let bottom = strip(from: bottomEdge - 7 * scale, to: bottomEdge - 4 * scale)
        guard let top, let bottom else { return }
        DispatchQueue.main.async {
            if self.top.map({ Self.distance($0, top) > 0.04 }) ?? true {
                Log.engine.notice("dock tone \(Self.describe(top), privacy: .public) → \(Self.describe(bottom), privacy: .public)")
            }
            if self.top != top { self.top = top }
            if self.bottom != bottom { self.bottom = bottom }
        }
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
    }

    private static func describe(_ color: NSColor) -> String {
        "(\(Int(color.redComponent * 255)), \(Int(color.greenComponent * 255)), \(Int(color.blueComponent * 255)))"
    }
}
