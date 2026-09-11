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
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let queue = DispatchQueue(label: "app.duo.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var starting = false
    private var retryAfter: CFTimeInterval = 0
    private var framesSinceStart = 0
    private(set) var isRunning = false

    func start(displayID: CGDirectDisplayID, pixelSize: CGSize, fps: Int) {
        guard !isRunning, !starting, CACurrentMediaTime() >= retryAfter else { return }
        starting = true

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else {
                    throw CocoaError(.featureUnsupported)
                }

                let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display,
                                             excludingApplications: ownApp.map { [$0] } ?? [],
                                             exceptingWindows: [])

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
                self.queue.sync { self.framesSinceStart = 0 }
                try await stream.startCapture()

                self.stream = stream
                self.isRunning = true
                self.starting = false
                Log.capture.info("started \(Int(pixelSize.width), privacy: .public)×\(Int(pixelSize.height), privacy: .public)")
            } catch {
                self.starting = false
                self.retryAfter = CACurrentMediaTime() + 3
                Log.capture.error("""
                    could not start (screen recording \(DesktopCapture.hasPermission ? "granted" : "missing", privacy: .public)): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    /// Drops the back-off after a failed start — used when the display comes back.
    func retrySoon() {
        retryAfter = 0
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        isRunning = false
        Log.capture.info("stopped")
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

        framesSinceStart += 1
        if framesSinceStart == 1 {
            Log.capture.info("first frame \(CVPixelBufferGetWidth(pixelBuffer), privacy: .public)×\(CVPixelBufferGetHeight(pixelBuffer), privacy: .public)")
        }
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            self.stream = nil
            self.isRunning = false
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPermissionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
