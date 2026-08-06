import Foundation

/// Every sound the game makes, ported from the web build's WebAudio graph.
///
/// There are no audio files anywhere in this project and there never were: each
/// of these is filtered noise or an oscillator with a scheduled envelope. That
/// is why the game works offline, why the bundle is small, and why the port is
/// a transcription rather than an asset pipeline.
public enum SoundBank {

    /// The building block — a decaying noise burst through a bandpass.
    /// Ported from `noiseBurst(dur, gain, fc, q)`.
    public static func noiseBurst(duration: Double, gain: Float, frequency: Double,
                                  q: Double = 0.8, pan: Float = 0, delay: Double = 0,
                                  seed: UInt32) -> Voice {
        var g = Envelope(startingAt: gain)
        g.set(gain, at: duration)
        return Voice(source: .noise(decay: true), duration: duration, gain: g,
                     filterFrequency: Envelope(startingAt: Float(frequency)),
                     filterQ: q, pan: pan, delay: delay, seed: seed)
    }

    // MARK: - Movement

    /// Footfall. The web build randomises the centre frequency per step, which
    /// is what stops a corridor sounding like a metronome.
    public static func footstep(running: Bool, seed: UInt32) -> Voice {
        var rng = Mulberry32(seed: seed)
        return noiseBurst(duration: 0.09, gain: running ? 0.34 : 0.20,
                          frequency: 520 + rng.nextUnit() * 320, q: 0.9, seed: seed)
    }

    public static func splash(running: Bool, seed: UInt32) -> [Voice] {
        [noiseBurst(duration: 0.16, gain: running ? 0.36 : 0.24, frequency: 640,
                    q: 0.7, seed: seed),
         noiseBurst(duration: 0.08, gain: 0.10, frequency: 1800, q: 1.0, seed: seed &+ 1)]
    }

    /// Heartbeat. `thump(amp)` — a sine dropping 58→38Hz in a tenth of a second.
    public static func thump(amplitude: Float) -> Voice {
        var f = Envelope(startingAt: 58)
        f.exponentialRamp(to: 38, at: 0.11)
        var g = Envelope(startingAt: 1e-5)
        g.exponentialRamp(to: amplitude, at: 0.015)
        g.exponentialRamp(to: 1e-5, at: 0.13)
        return Voice(source: .sine, duration: 0.15, gain: g, frequency: f)
    }

    // MARK: - Interface

    /// The exit's sonar pip. Panned toward the door, and the caller shortens the
    /// interval as you close, which is the whole navigation aid.
    public static func beep(gain: Float, pan: Float) -> Voice {
        var g = Envelope(startingAt: 0)
        g.linearRamp(to: gain, at: 0.012)
        g.exponentialRamp(to: 1e-5, at: 0.10)
        return Voice(source: .square, duration: 0.13, gain: g,
                     frequency: Envelope(startingAt: 1380), pan: pan)
    }

    public static func click(seed: UInt32) -> Voice {
        noiseBurst(duration: 0.03, gain: 0.15, frequency: 3000, q: 2, seed: seed)
    }

    public static func staticBurst(duration: Double, gain: Float, seed: UInt32) -> Voice {
        noiseBurst(duration: duration, gain: gain, frequency: 2400, q: 0.25, seed: seed)
    }

    // MARK: - Doors and transitions

    /// The exit door. A sawtooth sagging 92→58Hz under a lowpass, plus grit.
    public static func creak(seed: UInt32) -> [Voice] {
        var f = Envelope(startingAt: 92)
        f.exponentialRamp(to: 58, at: 0.7)
        var g = Envelope(startingAt: 1e-5)
        g.exponentialRamp(to: 0.12, at: 0.06)
        g.exponentialRamp(to: 1e-5, at: 0.8)
        let body = Voice(source: .sawtooth, duration: 0.85, gain: g, frequency: f,
                         filterFrequency: Envelope(startingAt: 420), filterQ: 0,
                         filterIsLowpass: true)
        return [body, noiseBurst(duration: 0.3, gain: 0.08, frequency: 300, q: 1.2, seed: seed)]
    }

    /// Descending a floor: a bandpass sweeping 1400→90Hz over noise.
    public static func whoosh(seed: UInt32) -> Voice {
        var fc = Envelope(startingAt: 1400)
        fc.exponentialRamp(to: 90, at: 1.35)
        var g = Envelope(startingAt: 1e-5)
        g.exponentialRamp(to: 0.4, at: 0.15)
        g.exponentialRamp(to: 1e-5, at: 1.45)
        return Voice(source: .noise(decay: false), duration: 1.5, gain: g,
                     filterFrequency: fc, filterQ: 1.5, seed: seed)
    }

    /// The camcorder losing power.
    public static func powerDown() -> Voice {
        var f = Envelope(startingAt: 110)
        f.exponentialRamp(to: 26, at: 0.5)
        var g = Envelope(startingAt: 0.06)
        g.exponentialRamp(to: 1e-5, at: 0.55)
        return Voice(source: .square, duration: 0.6, gain: g, frequency: f,
                     filterFrequency: Envelope(startingAt: 800), filterQ: 0,
                     filterIsLowpass: true)
    }

    // MARK: - The entity

    /// Something large, close, and not happy. 46→29Hz over a second.
    public static func growl(seed: UInt32) -> [Voice] {
        var f = Envelope(startingAt: 46)
        f.exponentialRamp(to: 29, at: 1.15)
        var g = Envelope(startingAt: 1e-5)
        g.exponentialRamp(to: 0.20, at: 0.22)
        g.exponentialRamp(to: 1e-5, at: 1.25)
        let body = Voice(source: .sawtooth, duration: 1.3, gain: g, frequency: f,
                         filterFrequency: Envelope(startingAt: 240), filterQ: 0,
                         filterIsLowpass: true)
        return [body, noiseBurst(duration: 0.6, gain: 0.10, frequency: 170, q: 0.8, seed: seed)]
    }

    public static func sightingSting(seed: UInt32) -> Voice {
        noiseBurst(duration: 0.18, gain: 0.12, frequency: 1200, q: 3, seed: seed)
    }

    public static func houndYelp(seed: UInt32) -> Voice {
        noiseBurst(duration: 0.14, gain: 0.22, frequency: 1900, q: 5, seed: seed)
    }

    /// The crawler's approach — three clicks in quick succession.
    public static func crawlerClicks(seed: UInt32) -> [Voice] {
        [noiseBurst(duration: 0.05, gain: 0.18, frequency: 2600, q: 6, delay: 0, seed: seed),
         noiseBurst(duration: 0.05, gain: 0.16, frequency: 2900, q: 6, delay: 0.07, seed: seed &+ 1),
         noiseBurst(duration: 0.05, gain: 0.14, frequency: 2400, q: 6, delay: 0.15, seed: seed &+ 2)]
    }

    /// Whispers off to one side. Three staggered narrow bursts, panned together
    /// so they read as coming from somewhere rather than everywhere.
    public static func whisper(seed: UInt32) -> [Voice] {
        var rng = Mulberry32(seed: seed)
        let side = Float(rng.nextUnit() * 2 - 1)
        return (0..<3).map { i in
            noiseBurst(duration: 0.16 + rng.nextUnit() * 0.2, gain: 0.030,
                       frequency: 900 + rng.nextUnit() * 1200, q: 3.2,
                       pan: side + Float(rng.nextUnit() - 0.5) * 0.4,
                       delay: Double(i) * 0.21 + rng.nextUnit() * 0.08,
                       seed: seed &+ UInt32(i) &+ 11)
        }
    }

    public static func hurt(seed: UInt32) -> [Voice] {
        [noiseBurst(duration: 0.22, gain: 0.28, frequency: 420, q: 1.1, seed: seed),
         thump(amplitude: 0.22)]
    }

    /// Caught. Two detuned sawtooths falling 170→46Hz under a wash of noise.
    public static func deathScream(seed: UInt32) -> [Voice] {
        var voices = [noiseBurst(duration: 0.7, gain: 0.5, frequency: 900, q: 1.2, seed: seed)]
        for detune in [0.0, 7.0] {
            var f = Envelope(startingAt: Float(170 + detune * 9))
            f.exponentialRamp(to: 46, at: 0.85)
            var g = Envelope(startingAt: 1e-5)
            g.exponentialRamp(to: 0.30, at: 0.07)
            g.exponentialRamp(to: 1e-5, at: 0.95)
            voices.append(Voice(source: .sawtooth, duration: 1.0, gain: g, frequency: f,
                                filterFrequency: Envelope(startingAt: 1200), filterQ: 0,
                                filterIsLowpass: true))
        }
        return voices
    }
}
