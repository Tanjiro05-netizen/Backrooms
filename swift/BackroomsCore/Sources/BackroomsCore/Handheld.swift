import Foundation

/// The hands holding the camcorder.
///
/// This is a port of the web build's `applyCamera` — the "handheld camcorder
/// compose" block — which never made it into the native port. Without it the
/// camera is welded to the player's eye and moves on rails, which is the
/// loudest possible tell in a game whose entire premise is that a person is
/// holding the camera.
///
/// Every constant here comes from the shipping web build rather than being
/// invented, because they were tuned against the real thing by someone
/// watching it move.
///
/// **This does not touch the simulation.** The entity's gaze checks and the
/// interaction picker read the player's actual heading; what this produces is
/// the *rendered* camera only. Smoothing the aim would change what counts as
/// looking at the creature, which is fixture-tested behaviour and not a
/// presentation decision.
public struct Handheld: Sendable {

    /// Where to put the camera this frame. Offsets add to the eye position;
    /// the angles are absolute and replace the camera's own.
    public struct Pose: Sendable, Equatable {
        public var offsetX: Float = 0
        public var offsetY: Float = 0
        public var offsetZ: Float = 0
        public var yaw: Float = 0
        public var pitch: Float = 0
        public var roll: Float = 0
    }

    // Smoothed look — the camera drags a hair behind the head.
    private var yawSmoothed: Double
    private var pitchSmoothed: Double = 0
    private var prevYaw: Double
    private var leanSmoothed: Double = 0
    /// Walk-cycle phase. Advances with ground covered, not with time, so the
    /// bob stays in step whether you are walking, sprinting or wading.
    private var bob: Double = 0
    /// Footfall impulse, decaying. The dip on each step is what separates a
    /// walk from a float.
    private var stepDip: Double = 0
    /// Raised when something hits you, decaying back down.
    private var shake: Double = 0
    private var seeded = false

    /// How far the camera drops on each footfall. The web build's value for
    /// this is applied inside its step handler rather than its camera block;
    /// this is scaled to sit just under the bob amplitude, so a step reads as
    /// a catch in the stride rather than a stumble.
    private static let stepDipImpulse = 0.016

    public init(initialYaw: Double = -Double.pi / 2) {
        yawSmoothed = initialYaw
        prevYaw = initialYaw
    }

    /// Something hit you. Shakes the operator, then settles.
    public mutating func kick(_ amount: Double = 0.05) {
        shake = Swift.max(shake, amount)
    }

    /// Snap the smoothing to a known heading — on spawn, or after a teleport,
    /// so the camera does not swing across the level catching up.
    public mutating func reset(yaw: Double, pitch: Double = 0) {
        yawSmoothed = yaw
        pitchSmoothed = pitch
        prevYaw = yaw
        leanSmoothed = 0
        bob = 0
        stepDip = 0
        shake = 0
    }

    /// Deterministic stand-in for the web build's `Math.random()` shake.
    ///
    /// The web can afford a real random here; this port cannot, because the
    /// session is stepped inside tests that must produce the same numbers
    /// twice. Two incommensurable frequencies give something that does not
    /// visibly repeat at the timescale a shake lasts.
    private func jitter(_ t: Double, _ salt: Double) -> Double {
        sin(t * 97.1 + salt) * 0.6 + sin(t * 61.7 + salt * 2.3) * 0.4
    }

    /// Compose one frame.
    ///
    /// - Parameters:
    ///   - yaw/pitch: where the player is actually looking, unsmoothed.
    ///   - moveAmount: ground speed, driving both bob rate and bob depth.
    ///   - strafe: −1…1 lateral input, for the lean into a sidestep.
    ///   - inWater: wading shortens the bob and slows the cycle.
    ///   - alive: everything damps to nothing on death.
    public mutating func update(dt: Double, time: Double,
                                yaw: Double, pitch: Double,
                                moveAmount: Double, strafe: Double,
                                inWater: Bool, alive: Bool) -> Pose {
        if !seeded {
            yawSmoothed = yaw
            pitchSmoothed = pitch
            prevYaw = yaw
            seeded = true
        }

        let live = alive ? 1.0 : 0.0

        // View inertia. Exponential rather than linear so the catch-up is
        // framerate-independent — a 120Hz display must not track tighter than
        // a 60Hz one.
        let ik = 1 - exp(-28 * dt)
        yawSmoothed += (yaw - yawSmoothed) * ik
        pitchSmoothed += (pitch - pitchSmoothed) * ik
        let yawVelocity = (yaw - prevYaw) / Swift.max(dt, 1e-4)
        prevYaw = yaw

        let mv = Swift.min(1, moveAmount / 3) * live

        // Walk cycle, advanced by speed. Crossing a half-cycle is a footfall.
        let previousBob = bob
        bob += dt * moveAmount * (inWater ? 1.4 : 1.9)
        if floor(previousBob / Double.pi) != floor(bob / Double.pi) {
            stepDip = Handheld.stepDipImpulse
        }

        // Vertical bob runs at twice the cycle (two steps per cycle); the
        // lateral term runs at the cycle itself, which is what makes the head
        // trace a figure-eight instead of pumping straight up and down.
        let bobY = sin(bob * 2) * (inWater ? 0.026 : 0.045) * mv
        let bobX = sin(bob) * 0.024 * mv
        let swayRoll = sin(bob) * 0.014 * mv
        stepDip *= Swift.max(0, 1 - dt * 9)

        // Lean into strafes and into turns.
        let leanTarget = (-strafe * 0.030
                          - Swift.max(-1, Swift.min(1, yawVelocity * 0.10)) * 0.020) * live
        leanSmoothed += (leanTarget - leanSmoothed) * Swift.min(1, dt * 8)

        // Breathing, which only shows when you are still enough to see it.
        let idle = (1 - mv) * live
        let breathY = sin(time * 1.1) * 0.006 * idle
        let breathPitch = sin(time * 1.1 + 0.6) * 0.004 * idle

        // The drift of a hand that cannot hold still. Layered frequencies, so
        // it never settles into a readable pattern — a single sine here reads
        // as a mechanical pan, which is worse than no movement at all.
        let driftYaw = sin(time * 0.9) * 0.012
                     + sin(time * 2.3 + 1.7) * 0.007
                     + sin(time * 5.1) * 0.003
        let driftPitch = sin(time * 1.1 + 4.0) * 0.010
                       + sin(time * 2.9) * 0.006
                       + sin(time * 6.3) * 0.0025
        let driftRoll = sin(time * 0.7 + 2.0) * 0.009
                      + sin(time * 3.7) * 0.004

        shake = Swift.max(0, shake - dt * 6)
        let shakePitch = jitter(time, 11.3) * shake
        let shakeYaw = jitter(time, 7.7) * shake
        let shakeRoll = jitter(time, 5.9) * shake * 0.9

        // The lateral bob is along the camera's right vector, not world X, or
        // it would slide sideways relative to the direction you face.
        let rightX = cos(yawSmoothed)
        let rightZ = -sin(yawSmoothed)

        var pose = Pose()
        pose.offsetX = Float(rightX * bobX)
        pose.offsetY = Float(bobY - stepDip + breathY)
        pose.offsetZ = Float(rightZ * bobX)
        pose.yaw = Float(yawSmoothed + driftYaw + shakeYaw)
        pose.pitch = Float(pitchSmoothed + driftPitch + breathPitch + shakePitch)
        pose.roll = Float(swayRoll + driftRoll + leanSmoothed + shakeRoll)
        return pose
    }
}
