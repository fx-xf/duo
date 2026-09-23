import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import QuartzCore

/// Streams the live desktop out of ScreenCaptureKit.
///
/// The overlay window sets `sharingType = .none` and Duo excludes itself from
/// the filter, so what comes back is the desktop without Duo on top of it.
///
/// Streams die on their own — every time the display sleeps, and now and then
/// for no reason given — so the state here is deliberately suspicious of itself:
/// a start that never returns and a stream that never delivers both count as
/// dead, and `checkHealth()` brings them back.
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let queue = DispatchQueue(label: "app.duo.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var starting = false
    /// When the attempt in flight began, or when the live stream came up.
    private var since: CFTimeInterval = 0
    private var retryAfter: CFTimeInterval = 0
    /// Bumped whenever the state moves on, so a start in flight can tell that it
    /// has been superseded by the time it finally returns.
    private var generation = 0

    private let counter = NSLock()
    private var framesSeen = 0

    private(set) var isRunning = false

    /// ScreenCaptureKit delivers the first frame as soon as a stream starts.
    /// Silence for this long means it came up dead.
    private static let firstFrameGrace: CFTimeInterval = 4
    /// SCShareableContent can hang while the display is off; without a deadline
    /// the app would sit on a start that never returns and never capture again.
    private static let startTimeout: CFTimeInterval = 8

    /// `hiddenWindows` are left out of the picture — the overlay itself. Duo's
    /// other windows, the widgets beside the Dock among them, are part of the
    /// desktop and fold along with it.
    func start(displayID: CGDirectDisplayID, pixelSize: CGSize, fps: Int, hiding hiddenWindows: [CGWindowID] = []) {
        let now = CACurrentMediaTime()
        if starting {
            guard now - since > Self.startTimeout else { return }
            Log.capture.notice("start never came back, trying again")
            starting = false
            generation += 1
        }
        guard !isRunning, now >= retryAfter else { return }

        starting = true
        since = now
        generation += 1
        let attempt = generation

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else {
                    throw CocoaError(.featureUnsupported)
                }

                let hidden = content.windows.filter { hiddenWindows.contains($0.windowID) }
                let filter = SCContentFilter(display: display, excludingWindows: hidden)

                let configuration = SCStreamConfiguration()
                configuration.width = Int(pixelSize.width)
                configuration.height = Int(pixelSize.height)
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.colorSpaceName = CGColorSpace.displayP3
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                configuration.queueDepth = 3
                configuration.showsCursor = false
                configuration.scalesToFit = false

                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                self.resetFrameCount()
                try await stream.startCapture()

                // The stream can die before this line is reached; if anything has
                // touched the state since, this one is already history.
                guard attempt == self.generation else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.isRunning = true
                self.starting = false
                self.since = CACurrentMediaTime()
                Log.capture.notice("started \(Int(pixelSize.width), privacy: .public)×\(Int(pixelSize.height), privacy: .public)")
            } catch {
                guard attempt == self.generation else { return }
                self.starting = false
                self.retryAfter = CACurrentMediaTime() + 3
                Log.capture.error("""
                    could not start (screen recording \(DesktopCapture.hasPermission ? "granted" : "missing", privacy: .public)): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    /// Catches a stream that came up dead: running, but nothing ever arrived.
    func checkHealth() {
        guard isRunning, frameCount == 0, CACurrentMediaTime() - since > Self.firstFrameGrace else { return }
        Log.capture.notice("no frames after starting, taking a fresh stream")
        restart()
    }

    func restart() {
        stop()
        retryAfter = 0
    }

    /// Drops the back-off after a failed start — used when the display comes back.
    func retrySoon() {
        retryAfter = 0
    }

    func stop() {
        generation += 1
        starting = false
        isRunning = false
        guard let stream else { return }
        self.stream = nil
        Log.capture.notice("stopped")
        Task {
            try? await stream.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Skip frames the compositor marked as "nothing changed".
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        counter.lock()
        framesSeen += 1
        let first = framesSeen == 1
        counter.unlock()
        if first {
            Log.capture.notice("first frame \(CVPixelBufferGetWidth(pixelBuffer), privacy: .public)×\(CVPixelBufferGetHeight(pixelBuffer), privacy: .public)")
        }
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async {
            // Deliberately not checking which stream this was: it can die before
            // the start that created it has even returned, and then matching on
            // identity would leave the app believing it still captures.
            self.generation += 1
            self.starting = false
            self.isRunning = false
            self.stream = nil
        }
    }

    private var frameCount: Int {
        counter.lock()
        defer { counter.unlock() }
        return framesSeen
    }

    private func resetFrameCount() {
        counter.lock()
        framesSeen = 0
        counter.unlock()
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPermissionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
