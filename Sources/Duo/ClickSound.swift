import AVFoundation

/// The soft click when the lid opens and the desktop clears.
/// Synthesised at launch so the app ships without audio assets.
final class ClickSound {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.35
        buffer = Self.makeClick(format: format)
    }

    func play() {
        guard let buffer else { return }
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            player.play()
        } catch {
            NSLog("Duo: could not play click — \(error.localizedDescription)")
        }
    }

    /// Two decaying sine partials under a fast exponential envelope, plus a
    /// pinch of noise for the mechanical edge — a hinge latch, not a beep.
    private static func makeClick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration = 0.09
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames

        var noiseState: Float = 0
        for frame in 0..<Int(frames) {
            let t = Double(frame) / sampleRate
            let envelope = Float(exp(-t * 105))
            let body = Float(sin(2 * .pi * 2_050 * t)) * 0.55
                + Float(sin(2 * .pi * 3_400 * t)) * 0.25
            noiseState = noiseState * 0.6 + Float.random(in: -1...1) * 0.4
            let attack = Float(exp(-t * 900)) * noiseState * 0.35
            let sample = (body + attack) * envelope * 0.8
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }
        return buffer
    }
}
