import Foundation

/// A two-pole IIR filter matching `BiquadFilterNode`.
///
/// Coefficients are the RBJ cookbook forms the Web Audio spec mandates, so a
/// sound tuned against the web build lands in the same place here.
///
/// One trap worth naming: the spec interprets `Q` **in decibels** for lowpass
/// and highpass, converting it as 10^(Q/20), but as a plain quality factor for
/// bandpass. The web build leans on both — `muffle.Q = 0.4` is dB, the noise
/// bursts' `Q` is not — so the two are separate constructors here rather than
/// one function with a flag somebody will eventually pass wrong.
public struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0
    private var y1: Float = 0, y2: Float = 0

    private init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// `Q` in decibels, as the spec defines it for this type.
    public static func lowpass(frequency: Double, qDecibels: Double,
                              sampleRate: Double) -> Biquad {
        let q = pow(10, qDecibels / 20)
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * max(q, 1e-4))
        let cosw = cos(w0)
        return Biquad(b0: Float((1 - cosw) / 2), b1: Float(1 - cosw), b2: Float((1 - cosw) / 2),
                      a0: Float(1 + alpha), a1: Float(-2 * cosw), a2: Float(1 - alpha))
    }

    /// `Q` as a plain quality factor, as the spec defines it for this type.
    /// Constant 0 dB peak gain.
    public static func bandpass(frequency: Double, q: Double,
                               sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * max(q, 1e-4))
        let cosw = cos(w0)
        return Biquad(b0: Float(alpha), b1: 0, b2: Float(-alpha),
                      a0: Float(1 + alpha), a1: Float(-2 * cosw), a2: Float(1 - alpha))
    }

    /// Direct form I. Cheap, and its state is the last two in/out pairs, which
    /// makes a voice's filter trivially resettable.
    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    public mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }
}
