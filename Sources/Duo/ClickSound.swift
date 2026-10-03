import AppKit

/// The soft click when the lid opens and the desktop clears.
/// Synthesised at launch so the app ships without audio assets.
///
/// Played through NSSound, which finds the current output afresh every time
/// and simply fails if there is none. An AVAudioEngine kept from launch does
/// not: after a long sleep, or a headset coming and going, it can still call
/// itself running with no audio flowing, and starting a player then throws an
/// Objective-C exception ("player did not see an IO cycle") that Swift cannot
/// catch — it took the whole app down as the lid opened.
final class ClickSound {
    private let sound: NSSound?

    init() {
        sound = Self.makeClick(sampleRate: 48_000).flatMap { NSSound(data: Self.wave($0, sampleRate: 48_000)) }
        sound?.volume = 0.35
    }

    func play() {
        guard let sound else { return }
        if sound.isPlaying { sound.stop() }
        if !sound.play() {
            Log.engine.notice("click could not play")
        }
    }

    /// Two decaying sine partials under a fast exponential envelope, plus a
    /// pinch of noise for the mechanical edge — a hinge latch, not a beep.
    private static func makeClick(sampleRate: Double) -> [Float]? {
        let duration = 0.09
        let frames = Int(duration * sampleRate)
        guard frames > 0 else { return nil }
        var samples = [Float](repeating: 0, count: frames)
        var noiseState: Float = 0
        for frame in 0..<frames {
            let t = Double(frame) / sampleRate
            let envelope = Float(exp(-t * 105))
            let body = Float(sin(2 * .pi * 2_050 * t)) * 0.55
                + Float(sin(2 * .pi * 3_400 * t)) * 0.25
            noiseState = noiseState * 0.6 + Float.random(in: -1...1) * 0.4
            let attack = Float(exp(-t * 900)) * noiseState * 0.35
            samples[frame] = (body + attack) * envelope * 0.8
        }
        return samples
    }

    /// The samples as a 16-bit stereo WAV file, in memory.
    private static func wave(_ samples: [Float], sampleRate: Int) -> Data {
        let channels = 2
        let bytesPerFrame = channels * 2
        let dataSize = samples.count * bytesPerFrame
        var data = Data(capacity: 44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(channels)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerFrame)); append(UInt16(bytesPerFrame)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * Float(Int16.max))
            for _ in 0..<channels { append(value) }
        }
        return data
    }
}
