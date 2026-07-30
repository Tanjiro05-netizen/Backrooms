import XCTest
@testable import BackroomsCore

/// Covers the synth. No audio hardware is touched — the mixer is a pure
/// renderer, which is the whole reason it lives in `BackroomsCore`: a sound
/// that comes out silent, clipped, or NaN is a bug you can catch in CI instead
/// of on a device with headphones.
final class AudioTests: XCTestCase {

    private let sampleRate = 48_000.0

    /// Peak absolute value over a rendered stretch, plus a NaN check.
    private func measure(_ mixer: AudioMixer, seconds: Double) -> (peak: Float, rms: Float) {
        let frames = 512
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        var sum: Double = 0
        var count = 0
        for _ in 0..<Int(seconds * sampleRate / Double(frames)) {
            mixer.render(left: &left, right: &right, frames: frames)
            for i in 0..<frames {
                XCTAssertFalse(left[i].isNaN || right[i].isNaN, "NaN in the output")
                peak = max(peak, max(abs(left[i]), abs(right[i])))
                sum += Double(left[i] * left[i] + right[i] * right[i])
                count += 2
            }
        }
        return (peak, Float((sum / Double(max(count, 1))).squareRoot()))
    }

    // MARK: - Biquad

    /// A lowpass has to pass DC and stop well above its corner. If the
    /// coefficients were wrong this is what would catch it.
    func testLowpassPassesLowAndStopsHigh() {
        var low = Biquad.lowpass(frequency: 400, qDecibels: 0, sampleRate: sampleRate)
        var high = Biquad.lowpass(frequency: 400, qDecibels: 0, sampleRate: sampleRate)

        func amplitude(_ filter: inout Biquad, hz: Double) -> Float {
            var peak: Float = 0
            let n = Int(sampleRate / 10)
            for i in 0..<n {
                let x = Float(sin(2 * Double.pi * hz * Double(i) / sampleRate))
                let y = filter.process(x)
                // Skip the settling transient.
                if i > n / 4 { peak = max(peak, abs(y)) }
            }
            return peak
        }

        let passed = amplitude(&low, hz: 50)
        let stopped = amplitude(&high, hz: 6000)
        XCTAssertGreaterThan(passed, 0.9, "a 400Hz lowpass should pass 50Hz")
        XCTAssertLessThan(stopped, 0.05, "a 400Hz lowpass should stop 6kHz")
    }

    /// A bandpass has to reject on *both* sides — a lowpass wired in by mistake
    /// would still pass the low test.
    func testBandpassRejectsBothSides() {
        func amplitude(hz: Double) -> Float {
            var filter = Biquad.bandpass(frequency: 1000, q: 2, sampleRate: sampleRate)
            var peak: Float = 0
            let n = Int(sampleRate / 5)
            for i in 0..<n {
                let x = Float(sin(2 * Double.pi * hz * Double(i) / sampleRate))
                let y = filter.process(x)
                if i > n / 3 { peak = max(peak, abs(y)) }
            }
            return peak
        }
        let centre = amplitude(hz: 1000)
        XCTAssertGreaterThan(centre, 0.8, "a bandpass should pass its centre near unity")
        XCTAssertLessThan(amplitude(hz: 60), centre * 0.2, "bandpass leaked low")
        XCTAssertLessThan(amplitude(hz: 15000), centre * 0.2, "bandpass leaked high")
    }

    /// The spec reads `Q` as decibels for lowpass and as a plain factor for
    /// bandpass. Getting that backwards changes every filtered sound in the
    /// game, so it is worth pinning that the two constructors differ.
    func testLowpassQIsDecibelsAndBandpassQIsNot() {
        var flat = Biquad.lowpass(frequency: 1000, qDecibels: 0, sampleRate: sampleRate)
        var resonant = Biquad.lowpass(frequency: 1000, qDecibels: 12, sampleRate: sampleRate)
        func peakAtCorner(_ filter: inout Biquad) -> Float {
            var peak: Float = 0
            let n = Int(sampleRate / 5)
            for i in 0..<n {
                let y = filter.process(Float(sin(2 * Double.pi * 1000 * Double(i) / sampleRate)))
                if i > n / 3 { peak = max(peak, abs(y)) }
            }
            return peak
        }
        XCTAssertGreaterThan(peakAtCorner(&resonant), peakAtCorner(&flat) * 1.5,
                             "12 dB of Q should ring noticeably at the corner")
    }

    // MARK: - Envelope

    func testEnvelopeHoldsStepsAndInterpolatesRamps() {
        var env = Envelope(startingAt: 0)
        env.set(0.5, at: 1.0)
        env.linearRamp(to: 1.0, at: 2.0)

        XCTAssertEqual(env.value(at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(env.value(at: 0.5), 0, accuracy: 1e-6, "a step holds until its time")
        XCTAssertEqual(env.value(at: 1.5), 0.75, accuracy: 1e-5, "linear ramps interpolate")
        XCTAssertEqual(env.value(at: 2.0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(env.value(at: 9.0), 1.0, accuracy: 1e-6, "the last value holds")
    }

    /// Exponential ramps are geometric, which is why the web build always ramps
    /// to 0.0001 rather than 0 — and why this one cannot be allowed to reach it.
    func testExponentialRampIsGeometricAndNeverReachesZero() {
        var env = Envelope(startingAt: 1.0)
        env.exponentialRamp(to: 0.01, at: 1.0)
        XCTAssertEqual(env.value(at: 0.5), 0.1, accuracy: 1e-4, "halfway should be the geometric mean")

        var toZero = Envelope(startingAt: 1.0)
        toZero.exponentialRamp(to: 0, at: 1.0)
        let end = toZero.value(at: 1.0)
        XCTAssertGreaterThan(end, 0, "an exponential ramp must not reach zero")
        XCTAssertLessThan(end, 1e-4)
    }

    // MARK: - Voices

    /// Every sound must make noise and stay in range. A silent voice is the
    /// failure mode you would never notice until someone reported "no audio".
    func testEverySoundIsAudibleAndBounded() {
        var cases: [(String, [Voice])] = [
            ("footstep", [SoundBank.footstep(running: false, seed: 1)]),
            ("sprint step", [SoundBank.footstep(running: true, seed: 2)]),
            ("splash", SoundBank.splash(running: true, seed: 3)),
            ("thump", [SoundBank.thump(amplitude: 0.22)]),
            ("beep", [SoundBank.beep(gain: 0.3, pan: 0)]),
            ("click", [SoundBank.click(seed: 4)]),
            ("static", [SoundBank.staticBurst(duration: 0.2, gain: 0.1, seed: 5)]),
            ("creak", SoundBank.creak(seed: 6)),
            ("whoosh", [SoundBank.whoosh(seed: 7)]),
            ("power down", [SoundBank.powerDown()]),
            ("growl", SoundBank.growl(seed: 8)),
            ("sting", [SoundBank.sightingSting(seed: 9)]),
            ("yelp", [SoundBank.houndYelp(seed: 10)]),
            ("crawler clicks", SoundBank.crawlerClicks(seed: 11)),
            ("whisper", SoundBank.whisper(seed: 12)),
            ("hurt", SoundBank.hurt(seed: 13)),
            ("death scream", SoundBank.deathScream(seed: 14))
        ]
        for (name, voices) in cases {
            let mixer = AudioMixer(sampleRate: sampleRate)
            // Silence the beds so the measurement is the voice alone.
            mixer.masterGain = 1
            mixer.play(voices)
            let longest = voices.map { $0.delay + $0.duration }.max() ?? 0
            let result = measure(mixer, seconds: longest + 0.1)
            XCTAssertGreaterThan(result.peak, 0.01, "\(name) is inaudible")
            XCTAssertLessThanOrEqual(result.peak, 1.0, "\(name) exceeded full scale")
        }
        XCTAssertFalse(cases.isEmpty)
    }

    func testVoicesRetireSoThePoolDoesNotFillUp() {
        let mixer = AudioMixer(sampleRate: sampleRate)
        mixer.play(SoundBank.footstep(running: false, seed: 1))
        XCTAssertEqual(mixer.activeVoiceCount, 1)
        _ = measure(mixer, seconds: 0.5)     // the step is 0.09s long
        XCTAssertEqual(mixer.activeVoiceCount, 0, "a finished voice was never reclaimed")
    }

    /// Dropping rather than voice-stealing is deliberate; either way the pool
    /// must not grow without bound.
    func testVoicePoolIsCapped() {
        let mixer = AudioMixer(sampleRate: sampleRate)
        for i in 0..<200 {
            mixer.play(SoundBank.footstep(running: false, seed: UInt32(i)))
        }
        XCTAssertEqual(mixer.activeVoiceCount, AudioMixer.maxVoices)
    }

    func testPanSendsSoundToTheRightSide() {
        let frames = 4096
        func energy(pan: Float) -> (Float, Float) {
            let mixer = AudioMixer(sampleRate: sampleRate)
            mixer.masterGain = 1
            mixer.play(SoundBank.beep(gain: 0.5, pan: pan))
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            var l: Float = 0, r: Float = 0
            for _ in 0..<8 {
                mixer.render(left: &left, right: &right, frames: frames)
                for i in 0..<frames { l = max(l, abs(left[i])); r = max(r, abs(right[i])) }
            }
            return (l, r)
        }
        let hardLeft = energy(pan: -1)
        XCTAssertGreaterThan(hardLeft.0, hardLeft.1 * 4, "pan -1 should be mostly left")
        let hardRight = energy(pan: 1)
        XCTAssertGreaterThan(hardRight.1, hardRight.0 * 4, "pan +1 should be mostly right")
    }

    // MARK: - Beds and limiting

    /// The room is never silent — that bed is most of the dread.
    func testTheRoomHumIsAlwaysThere() {
        let mixer = AudioMixer(sampleRate: sampleRate)
        let result = measure(mixer, seconds: 0.5)
        XCTAssertGreaterThan(result.rms, 1e-4, "the ambient bed is silent")
        XCTAssertLessThan(result.peak, 0.5, "the bed alone should sit well under full scale")
    }

    func testBedLevelsRespondToTheirControls() {
        let quiet = AudioMixer(sampleRate: sampleRate)
        let quietRms = measure(quiet, seconds: 0.4).rms

        let loud = AudioMixer(sampleRate: sampleRate)
        loud.droneLevel = 0.5
        loud.waterLevel = 0.05
        loud.breathLevel = 0.05
        let loudRms = measure(loud, seconds: 0.4).rms
        XCTAssertGreaterThan(loudRms, quietRms * 1.5, "raising the beds did nothing")
    }

    /// Everything the game can throw at once, at maximum, must not clip.
    func testAPileUpStaysInsideFullScale() {
        let mixer = AudioMixer(sampleRate: sampleRate)
        mixer.droneLevel = 1
        mixer.waterLevel = 0.2
        mixer.breathLevel = 0.2
        mixer.play(SoundBank.deathScream(seed: 1))
        mixer.play(SoundBank.growl(seed: 2))
        mixer.play(SoundBank.crawlerClicks(seed: 3))
        mixer.play(SoundBank.whoosh(seed: 4))
        mixer.play(SoundBank.hurt(seed: 5))
        let result = measure(mixer, seconds: 1.6)
        XCTAssertLessThanOrEqual(result.peak, 1.0, "the limiter let it clip")
        XCTAssertGreaterThan(result.peak, 0.3, "that should be loud")
    }

    func testMuffleCutoffActuallyDarkensTheOutput() {
        func brightness(cutoff: Double) -> Float {
            let mixer = AudioMixer(sampleRate: sampleRate)
            mixer.masterGain = 1
            mixer.muffleCutoff = cutoff
            mixer.play(SoundBank.staticBurst(duration: 0.4, gain: 0.4, seed: 7))
            return measure(mixer, seconds: 0.5).rms
        }
        // Static is centred at 2.4kHz, so a 900Hz occlusion lowpass should eat
        // most of it — that difference is how you tell a hunt behind a wall
        // from one in the room with you.
        XCTAssertLessThan(brightness(cutoff: 900), brightness(cutoff: 19_000) * 0.6)
    }
}
