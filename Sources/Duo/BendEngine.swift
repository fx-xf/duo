import AppKit
import Combine
import QuartzCore

/// Drives the whole effect: sensor in, folded desktop out.
final class BendEngine: ObservableObject {
    @Published private(set) var rawAngle: Double = 130
    @Published private(set) var progress: Double = 0
    @Published private(set) var hasSensor = false

    private let prefs = Preferences.shared
    private let capture = DesktopCapture()
    private let click = ClickSound()
    private var sensor: LidAngleSensor?
    private var sensorFailures = 0
    private var model: LidModel
    private var overlay: OverlayController?
    private var overlayScreenKey: String?
    private var frameRate: Double = 60

    /// Frames arrive on the capture queue; the overlay is swapped on main.
    private let sinkLock = NSLock()
    private var frameSink: BendRenderer?

    private var timer: DispatchSourceTimer?
    private var currentInterval: Double = 0
    private var lastTick = CACurrentMediaTime()
    private var lastReading: Double = 130
    private var quietTicks = 0
    private var displayAsleep = false

    private var bendActive = false
    private var reachedFullBend = false
    private var cancellables = Set<AnyCancellable>()

    var isCapturing: Bool { capture.isRunning }

    init() {
        let sensor = LidAngleSensor()
        let angle = sensor?.read() ?? Preferences.shared.manualAngle
        self.sensor = sensor
        model = LidModel(angle: angle)
        hasSensor = sensor != nil
        if !hasSensor { prefs.followLid = false }
        rawAngle = angle
        lastReading = angle

        Log.engine.notice("""
            launch: lid sensor \(self.hasSensor ? "found" : "missing", privacy: .public), \
            angle \(Int(angle), privacy: .public)°, \
            screen recording \(DesktopCapture.hasPermission ? "granted" : "missing", privacy: .public), \
            follow lid \(self.prefs.followLid, privacy: .public)
            """)

        capture.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.sinkLock.lock()
            let sink = self.frameSink
            self.sinkLock.unlock()
            sink?.submit(frame: buffer)
        }

        rebuildOverlay()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.rebuildOverlay()
                // A display that reconfigured itself leaves the old stream dead.
                self.capture.restart()
            }
            .store(in: &cancellables)

        // Deliberately no reset around sleep: the overlay keeps its last, folded
        // frame through the dark, so opening the lid plays the unfold from there.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.displayAsleep = true
                Log.engine.info("display asleep at \(Int(self.lastReading), privacy: .public)°")
            }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.displayAsleep = false
                self.capture.retrySoon()
                Log.engine.info("display awake at \(Int(self.lastReading), privacy: .public)°")
            }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.displayAsleep = false
                // Sleep is hard on both of these: the stream rarely survives it,
                // and the sensor's HID handle does not always come back either.
                self.capture.restart()
                self.sensor = LidAngleSensor() ?? self.sensor
                Log.engine.notice("woke at \(Int(self.lastReading), privacy: .public)°, taking a fresh stream")
            }
            .store(in: &cancellables)

        prefs.$paused
            .dropFirst()
            .sink { [weak self] paused in
                guard paused, let self else { return }
                self.endBend()
                self.capture.stop()
            }
            .store(in: &cancellables)

        schedule(interval: 1.0 / 30)
    }

    private func endBend() {
        overlay?.hide()
        progress = 0
        bendActive = false
        reachedFullBend = false
    }

    /// Screen parameters also "change" when the display merely sleeps and wakes;
    /// only a real change to the built-in panel warrants a new overlay.
    private func rebuildOverlay() {
        let screen = NSScreen.builtIn
        let key = screen.map { "\($0.displayID) \($0.frame) \($0.backingScaleFactor)" }
        guard key != overlayScreenKey || overlay == nil else { return }
        overlayScreenKey = key

        endBend()
        capture.stop()
        overlay = screen.flatMap(OverlayController.init(screen:))
        frameRate = Double(max(screen?.maximumFramesPerSecond ?? 60, 30))
        sinkLock.lock()
        frameSink = overlay?.renderer
        sinkLock.unlock()
        if overlay == nil {
            Log.engine.error("no Metal overlay available")
        }
    }

    private func schedule(interval: Double) {
        guard interval != currentInterval else { return }
        currentInterval = interval
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// The live hinge angle, or the manual one. A failed read holds the last
    /// angle instead of jumping, and the sensor is reopened in case its HID
    /// handle did not survive sleep.
    private func currentTarget() -> Double {
        guard prefs.followLid, hasSensor else { return prefs.manualAngle }
        if let reading = sensor?.read() {
            sensorFailures = 0
            return reading
        }
        sensorFailures += 1
        if sensorFailures % 60 == 1 {
            Log.engine.error("lid sensor did not answer, reopening it")
            sensor = LidAngleSensor()
        }
        return lastReading
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now

        guard !prefs.paused, let overlay else {
            schedule(interval: 1.0 / 10)
            return
        }

        // Keep the stream warm: starting one takes longer than a lid takes to
        // close, and on a still desktop it delivers next to nothing anyway.
        if !capture.isRunning, !displayAsleep {
            capture.start(displayID: overlay.displayID, pixelSize: overlay.pixelSize, fps: 60)
        } else {
            capture.checkHealth()
        }

        let target = currentTarget()
        if rawAngle != target { rawAngle = target }
        let lidMoving = abs(target - lastReading) > 0.25
        lastReading = target

        // The screens-woke notification does not always arrive — on this Mac it
        // never does — so a lid on the move is proof enough that the display is
        // back and the capture is worth another try.
        if lidMoving, displayAsleep {
            displayAsleep = false
            capture.retrySoon()
        }

        model.startAngle = prefs.startAngle
        model.dynamic = prefs.dynamicFold
        let fold = model.step(target: target, dt: dt)
        progress = fold

        // A little hysteresis so sensor jitter at the threshold can't flicker it.
        let active = fold > (bendActive ? 0.0005 : 0.002)
        if active != bendActive {
            bendActive = active
            if active {
                Log.engine.info("""
                    fold in at \(Int(target), privacy: .public)°, starts below \(Int(self.model.startAngle), privacy: .public)°, \
                    frame ready \(overlay.renderer.hasFrame, privacy: .public), \
                    capturing \(self.capture.isRunning, privacy: .public)
                    """)
            } else {
                Log.engine.info("cleared at \(Int(target), privacy: .public)°")
                overlay.hide()
                if reachedFullBend {
                    prefs.bendCount += 1
                    if prefs.soundEnabled { click.play() }
                }
                reachedFullBend = false
            }
        }

        if active {
            if !displayAsleep {
                overlay.render(BendParams(tilt: model.tilt * .pi / 180,
                                          perspective: prefs.perspective,
                                          blur: prefs.blur,
                                          shadow: prefs.shadow))
            }
            if fold > 0.5 { reachedFullBend = true }
        }

        let busy = lidMoving || abs(model.springVelocity) > 0.5 || active
        quietTicks = busy ? 0 : quietTicks + 1
        schedule(interval: quietTicks > 30 || displayAsleep ? 1.0 / 30 : 1.0 / frameRate)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static var builtIn: NSScreen? {
        screens.first { CGDisplayIsBuiltin($0.displayID) != 0 } ?? screens.first
    }
}
