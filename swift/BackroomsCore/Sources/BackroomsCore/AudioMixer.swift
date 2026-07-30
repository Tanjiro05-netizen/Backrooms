import Foundation

/// The whole audio scene: a pool of one-shot voices over four continuous beds,
/// through a master gain and the occlusion lowpass.
///
/// Deliberately a pure renderer with no platform dependency — hand it a buffer
/// and it fills it. That means the synth is unit-testable on any machine, the
/// same reason the map generator and texture synthesis live here, and the
/// platform layer shrinks to "pump this into an `AVAudioSourceNode`".
public final class AudioMixer {

    /// Beyond this, new sounds are dropped rather than stealing an existing
    /// voice. Backrooms audio is sparse; hitting this ceiling means something
    /// upstream is spamming triggers.
    public static let maxVoices = 24

    public let sampleRate: Double

    /// Overall level, `masterGain` in the web build.
    public var masterGain: Float = 0.9
    /// Occlusion. The web build sweeps this lowpass down when the listener is
    /// behind geometry, so a hunt on the other side of a wall is muffled rather
    /// than merely quieter.
    public var muffleCutoff: Double = 19_000

    /// The Poolrooms' water, faded in with proximity.
    public var waterLevel: Float = 0
    /// Nervous breathing — silent until stamina or nerve gives out.
    public var breathLevel: Float = 0
    /// The hunt drone, and where it sits in the stereo field.
    public var droneLevel: Float = 0
    public var dronePan: Float = 0

    private var voices: [Voice] = []

    // Beds. Each is a looping generator rather than a stored buffer: the web
    // build loops a 2s brown-noise buffer at several playback rates, and a
    // generator reproduces that without holding the samples.
    private var roomNoise: BrownNoise
    private var waterNoise: BrownNoise
    private var breathNoise: BrownNoise
    private var roomFilter: Biquad
    private var waterFilter: Biquad
    private var breathFilter: Biquad
    private var droneFilter: Biquad
    private var humPhase1: Double = 0
    private var humPhase2: Double = 0
    private var dronePhase1: Double = 0
    private var dronePhase2: Double = 0
    private var muffle: Biquad
    private var muffleCutoffApplied: Double = -1
    private var scratchLeft: [Float] = []
    private var scratchRight: [Float] = []

    /// Brown-ish noise — the web build's `(last + 0.02*w) / 1.02` integrator,
    /// which is what gives the room bed its low rumble instead of hiss.
    private struct BrownNoise {
        var rng: Mulberry32
        var last: Float = 0
        var rate: Double
        var accumulator: Double = 0

        mutating func next() -> Float {
            accumulator += rate
            while accumulator >= 1 {
                accumulator -= 1
                let w = Float(rng.nextUnit() * 2 - 1)
                last = (last + 0.02 * w) / 1.02
            }
            return last * 3.0
        }
    }

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        roomNoise = BrownNoise(rng: Mulberry32(seed: 8_011), rate: 1.0)
        waterNoise = BrownNoise(rng: Mulberry32(seed: 8_017), rate: 0.5)
        breathNoise = BrownNoise(rng: Mulberry32(seed: 8_023), rate: 1.4)
        roomFilter = Biquad.lowpass(frequency: 400, qDecibels: 0, sampleRate: sampleRate)
        waterFilter = Biquad.bandpass(frequency: 220, q: 0.8, sampleRate: sampleRate)
        breathFilter = Biquad.bandpass(frequency: 520, q: 0.6, sampleRate: sampleRate)
        droneFilter = Biquad.lowpass(frequency: 230, qDecibels: 4, sampleRate: sampleRate)
        muffle = Biquad.lowpass(frequency: 19_000, qDecibels: 0.4, sampleRate: sampleRate)
    }

    // MARK: - Triggering

    public func play(_ voice: Voice) {
        guard voices.count < AudioMixer.maxVoices else { return }
        voices.append(voice)
    }

    public func play(_ group: [Voice]) {
        for voice in group { play(voice) }
    }

    public var activeVoiceCount: Int { voices.count }

    public func stopAll() { voices.removeAll() }

    // MARK: - Render

    /// Fills `left` and `right` with `frames` samples, replacing their contents.
    public func render(left: inout [Float], right: inout [Float], frames: Int) {
        if left.count < frames { left = [Float](repeating: 0, count: frames) }
        if right.count < frames { right = [Float](repeating: 0, count: frames) }
        if scratchLeft.count < frames {
            scratchLeft = [Float](repeating: 0, count: frames)
            scratchRight = [Float](repeating: 0, count: frames)
        }
        for i in 0..<frames { scratchLeft[i] = 0; scratchRight[i] = 0 }

        // Beds first.
        let step = 1.0 / sampleRate
        let droneAngle = (Double(max(-1, min(1, dronePan))) + 1) * 0.25 * Double.pi
        let dgl = Float(cos(droneAngle)), dgr = Float(sin(droneAngle))
        for i in 0..<frames {
            var mono = roomFilter.process(roomNoise.next()) * 0.05
            if waterLevel > 0 { mono += waterFilter.process(waterNoise.next()) * waterLevel }
            if breathLevel > 0 { mono += breathFilter.process(breathNoise.next()) * breathLevel }

            // The room's mains hum: 120Hz with its second harmonic.
            humPhase1 += 120 * step; if humPhase1 >= 1 { humPhase1 -= 1 }
            humPhase2 += 240 * step; if humPhase2 >= 1 { humPhase2 -= 1 }
            mono += Float(sin(humPhase1 * 2 * .pi)) * 0.012
            mono += Float(sin(humPhase2 * 2 * .pi)) * 0.005

            scratchLeft[i] += mono
            scratchRight[i] += mono

            // The drone is panned, so it is summed separately.
            if droneLevel > 0 {
                dronePhase1 += 36.0 * step; if dronePhase1 >= 1 { dronePhase1 -= 1 }
                dronePhase2 += 36.7 * step; if dronePhase2 >= 1 { dronePhase2 -= 1 }
                let saw = Float(dronePhase1 * 2 - 1) + Float(dronePhase2 * 2 - 1)
                let d = droneFilter.process(saw) * droneLevel
                scratchLeft[i] += d * dgl
                scratchRight[i] += d * dgr
            }
        }

        // One-shots.
        for index in voices.indices {
            voices[index].render(into: &scratchLeft, right: &scratchRight,
                                 frames: frames, sampleRate: sampleRate)
        }
        voices.removeAll { $0.isFinished }

        // Master gain, occlusion, and a soft limiter so a pile-up of bursts
        // cannot clip the output.
        if abs(muffleCutoff - muffleCutoffApplied) > 1 {
            muffle = Biquad.lowpass(frequency: muffleCutoff, qDecibels: 0.4,
                                    sampleRate: sampleRate)
            muffleCutoffApplied = muffleCutoff
        }
        for i in 0..<frames {
            left[i] = AudioMixer.limit(muffle.process(scratchLeft[i] * masterGain))
            right[i] = AudioMixer.limit(muffle.process(scratchRight[i] * masterGain))
        }
    }

    /// Soft knee above 0.7, hard ceiling at 1. Cheap, and it keeps the death
    /// scream — which stacks three voices — from squaring off.
    @inline(__always)
    static func limit(_ x: Float) -> Float {
        if x > 0.7 { return min(1, 0.7 + (x - 0.7) / (1 + (x - 0.7) * 2)) }
        if x < -0.7 { return max(-1, -0.7 + (x + 0.7) / (1 - (x + 0.7) * 2)) }
        return x
    }
}
