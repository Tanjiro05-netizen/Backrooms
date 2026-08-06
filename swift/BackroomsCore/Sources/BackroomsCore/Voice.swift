import Foundation

/// One playing sound: a source, an optional filter, a gain envelope, a pan.
///
/// This is the shape every sound in the web build takes — an oscillator or a
/// noise buffer, through one biquad, through one gain with a scheduled curve.
/// Rendering it here rather than assembling an `AVAudioEngine` node graph per
/// shot keeps the envelope and filter semantics identical to the web build's
/// and, more usefully, keeps the whole synth testable without audio hardware.
public struct Voice {

    public enum Source {
        case sine, sawtooth, square
        /// White noise. `decay` fades it linearly across the voice's life, which
        /// is how the web build's `noiseBurst` shapes its buffer.
        case noise(decay: Bool)
    }

    public var source: Source
    /// Constant pitch, or a sweep. Ignored by noise sources.
    public var frequency: Envelope
    public var gain: Envelope
    /// Filter cutoff can sweep too — `whoosh` is a bandpass falling 1400→90Hz.
    public var filterFrequency: Envelope?
    public var filterQ: Double = 0.8
    public var filterIsLowpass = false
    /// −1 hard left, +1 hard right.
    public var pan: Float = 0
    /// Seconds before the voice starts, for the scheduled bursts the director
    /// stacks up.
    public var delay: Double = 0
    public var duration: Double

    private var phase: Double = 0
    private var filter: Biquad?
    private var filterReady = false
    private var elapsed: Double = 0
    private var rng: Mulberry32

    public init(source: Source, duration: Double, gain: Envelope,
                frequency: Envelope = Envelope(startingAt: 440),
                filterFrequency: Envelope? = nil, filterQ: Double = 0.8,
                filterIsLowpass: Bool = false, pan: Float = 0, delay: Double = 0,
                seed: UInt32 = 1) {
        self.source = source
        self.duration = duration
        self.gain = gain
        self.frequency = frequency
        self.filterFrequency = filterFrequency
        self.filterQ = filterQ
        self.filterIsLowpass = filterIsLowpass
        self.pan = pan
        self.delay = delay
        self.rng = Mulberry32(seed: seed)
    }

    /// True once the voice has played out and can be recycled.
    public var isFinished: Bool { elapsed >= delay + duration }

    /// Adds this voice into the given stereo buffers. Additive so a pool of
    /// voices can share one pass.
    public mutating func render(into left: inout [Float], right: inout [Float],
                                frames: Int, sampleRate: Double) {
        let step = 1.0 / sampleRate
        // Equal-power pan, which is what StereoPannerNode uses.
        let angle = (Double(max(-1, min(1, pan))) + 1) * 0.25 * Double.pi
        let gl = Float(cos(angle)), gr = Float(sin(angle))

        for i in 0..<frames {
            let local = elapsed - delay
            elapsed += step
            guard local >= 0, local < duration else { continue }

            var sample: Float
            switch source {
            case .noise(let decay):
                sample = Float(rng.nextUnit() * 2 - 1)
                if decay { sample *= Float(1 - local / duration) }
            case .sine, .sawtooth, .square:
                let f = Double(frequency.value(at: local))
                phase += f * step
                if phase >= 1 { phase -= floor(phase) }
                switch source {
                case .sine:     sample = Float(sin(phase * 2 * Double.pi))
                case .sawtooth: sample = Float(phase * 2 - 1)
                default:        sample = phase < 0.5 ? 1 : -1
                }
            }

            if let filterFrequency {
                // Rebuilt as the cutoff sweeps. Recomputing coefficients every
                // sample would be wasteful and inaudible, so this tracks the
                // sweep in 64-sample steps.
                if !filterReady || i % 64 == 0 {
                    let fc = Double(filterFrequency.value(at: local))
                    filter = filterIsLowpass
                        ? Biquad.lowpass(frequency: fc, qDecibels: filterQ, sampleRate: sampleRate)
                        : Biquad.bandpass(frequency: fc, q: filterQ, sampleRate: sampleRate)
                    filterReady = true
                }
                if var f = filter {
                    sample = f.process(sample)
                    filter = f
                }
            }

            sample *= gain.value(at: local)
            left[i] += sample * gl
            right[i] += sample * gr
        }
    }
}
