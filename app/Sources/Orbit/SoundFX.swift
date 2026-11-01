import AVFoundation
import Foundation

/// Orbit's little sounds, synthesized on the fly: a pen on the screen, a pop when a label lands, a tap for a sticky
/// note. Quiet on purpose; they confirm what's happening rather than call for attention.
@MainActor
final class SoundFX {
    static let shared = SoundFX()

    enum Effect {
        case pen(Double), marker(Double), pop, badge, press, ping, clear
    }

    var enabled = true
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var cache: [String: AVAudioPCMBuffer] = [:]

    func play(_ effect: Effect) {
        guard enabled, start() else { return }
        let buffer: AVAudioPCMBuffer?
        switch effect {
        case .pen(let seconds): buffer = Self.scratch(seconds: seconds, low: 2200, high: 5200, level: 0.07)
        case .marker(let seconds): buffer = Self.scratch(seconds: seconds, low: 900, high: 2400, level: 0.06)
        case .pop: buffer = cached("pop") { Self.blip(from: 880, to: 520, seconds: 0.08, level: 0.22) }
        case .badge: buffer = cached("badge") { Self.blip(from: 1320, to: 840, seconds: 0.07, level: 0.2) }
        case .press: buffer = cached("press") { Self.thump() }
        case .ping: buffer = cached("ping") { Self.ping() }
        case .clear: buffer = cached("clear") { Self.whoosh() }
        }
        guard let buffer else { return }
        let player = players[next]
        next = (next + 1) % players.count
        player.stop()
        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()
    }

    private func start() -> Bool {
        if engine.isRunning { return true }
        if players.isEmpty {
            for _ in 0..<6 {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                players.append(player)
            }
        }
        do { try engine.start(); return true } catch { return false }
    }

    private func cached(_ key: String, _ make: () -> AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        if let hit = cache[key] { return hit }
        let made = make()
        cache[key] = made
        return made
    }

    // MARK: Synthesis

    nonisolated static let rate = 44_100.0

    private static func buffer(seconds: Double, _ sample: (Int, Double) -> Float) -> AVAudioPCMBuffer? {
        let count = max(1, Int(seconds * rate))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        let out = buffer.floatChannelData![0]
        for i in 0..<count { out[i] = sample(i, Double(i) / rate) }
        return buffer
    }

    /// A short pitched drop, like a soft gel pill landing.
    static func blip(from f0: Double, to f1: Double, seconds: Double, level: Float) -> AVAudioPCMBuffer? {
        var phase = 0.0
        return buffer(seconds: seconds) { _, t in
            let f = f1 + (f0 - f1) * exp(-t / (seconds * 0.35))
            phase += 2 * .pi * f / rate
            let env = min(1, t / 0.003) * exp(-t / (seconds * 0.3))
            return Float(sin(phase) + 0.25 * sin(phase * 2)) * Float(env) * level
        }
    }

    /// Paper pressed onto the screen: a low soft thump with a breath of noise.
    static func thump() -> AVAudioPCMBuffer? {
        var phase = 0.0, noise = Noise(), smooth: Float = 0
        return buffer(seconds: 0.16) { _, t in
            let f = 90 + 90 * exp(-t / 0.03)
            phase += 2 * .pi * f / rate
            smooth += (noise.next() - smooth) * 0.08
            let env = min(1, t / 0.004) * exp(-t / 0.045)
            return (Float(sin(phase)) * 0.3 + smooth * 0.35) * Float(env)
        }
    }

    /// A clear little ring for a spot to look at.
    static func ping() -> AVAudioPCMBuffer? {
        buffer(seconds: 0.35) { _, t in
            let env = min(1, t / 0.002) * exp(-t / 0.09)
            return Float(sin(2 * .pi * 1560 * t) * 0.7 + sin(2 * .pi * 2340 * t) * 0.18) * Float(env) * 0.12
        }
    }

    /// A soft sweep, like a page wiped clean.
    static func whoosh() -> AVAudioPCMBuffer? {
        var noise = Noise(), filter = BandPass(low: 600, high: 4000)
        return buffer(seconds: 0.3) { _, t in
            let sweep = 4000 - 3200 * (t / 0.3)
            filter.tune(low: sweep * 0.4, high: sweep)
            let env = sin(.pi * min(1, t / 0.3))
            return filter.process(noise.next()) * Float(env) * 0.35
        }
    }

    /// Band-limited noise with a grainy wobble: a felt pen or highlighter moving across glass.
    static func scratch(seconds: Double, low: Double, high: Double, level: Float) -> AVAudioPCMBuffer? {
        var noise = Noise(), filter = BandPass(low: low, high: high), wobble = Noise()
        var grain: Float = 0.5
        let length = max(0.08, seconds)
        return buffer(seconds: length) { i, t in
            if i % 300 == 0 { grain = 0.55 + 0.45 * abs(wobble.next()) }
            let env = min(1, t / 0.03) * min(1, (length - t) / 0.06)
            return filter.process(noise.next()) * grain * Float(max(0, env)) * level * 4
        }
    }

    /// Cheap white noise in -1...1 (xorshift).
    struct Noise {
        var state: UInt32 = 0x9E37_79B9
        mutating func next() -> Float {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return Float(state) / Float(UInt32.max) * 2 - 1
        }
    }

    /// A two-pole band-pass (RBJ cookbook), retunable while running.
    struct BandPass {
        private var b0: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        init(low: Double, high: Double) { tune(low: low, high: high) }
        mutating func tune(low: Double, high: Double) {
            let center = sqrt(max(low, 20) * max(high, low + 1)), bandwidth = max(high - low, 1)
            let w = 2 * Double.pi * center / SoundFX.rate, q = center / bandwidth
            let alpha = sin(w) / (2 * q), a0 = 1 + alpha
            b0 = Float(alpha / a0); b2 = Float(-alpha / a0)
            a1 = Float(-2 * cos(w) / a0); a2 = Float((1 - alpha) / a0)
        }
        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
}
