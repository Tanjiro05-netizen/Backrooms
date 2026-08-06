#if canImport(Metal)
import Foundation
import BackroomsCore

/// Swift mirror of the MSL `VHSUniforms`. Three `float4`s, same reasoning as
/// `SceneUniforms`: an all-`float4` layout cannot silently disagree across the
/// language boundary.
public struct VHSUniforms: Equatable {

    /// Master amount. 0 is a clean digital picture; 1 is a well-worn tape.
    /// Everything else scales off this, so one slider covers the whole look.
    public var intensity: Float = 0.85
    /// Seconds since the run started — drives every time-varying artifact.
    public var time: Float = 0
    /// Transient signal trouble. Raised when something is close.
    public var glitch: Float = 0
    /// The picture giving out entirely.
    public var dead: Float = 0

    /// Nightshot.
    public var infrared: Float = 0
    /// Battery about to go; adds noise and instability.
    public var lowBattery: Float = 0
    /// Air shimmer, for the floor that has it.
    public var heat: Float = 0
    /// Rate of oxide dropouts.
    public var dropout: Float = 0.15

    /// 1 crops the picture to a 4:3 camcorder window.
    public var aspect43: Float = 0
    /// Chroma gain. Tape does not hold saturation well.
    public var saturation: Float = 0.92
    public var resolutionX: Float = 0
    public var resolutionY: Float = 0

    public init() {}

    /// 3 float4s.
    public static let floatCount = 12

    public func packed() -> [Float] {
        [time, intensity, glitch, dead,
         infrared, lowBattery, heat, dropout,
         aspect43, saturation, resolutionX, resolutionY]
    }

    /// Derives the tape's condition from what is happening in the game.
    ///
    /// The picture degrading *is* the warning system — the web build ties the
    /// same signals to the same knobs, so a player who learns to read the tape
    /// on one build can read it on the other.
    public mutating func apply(session: GameSession, elapsed: Double) {
        time = Float(elapsed)
        heat = session.map.spec.theme == .pipes ? 1 : 0
        dead = session.phase == .dead ? 1 : 0

        // Proximity, not the hunt flag: the tape should already be struggling
        // before you know why.
        if let d = session.hunterDistance {
            let closeness = Float(max(0, min(1, (26.0 - d) / 26.0)))
            glitch = closeness * closeness * 0.55
            dropout = 0.15 + closeness * 0.5
        } else {
            glitch = 0
            dropout = 0.15
        }

        // A sighting corrupts the tape the longer you hold it in frame. That is
        // the tell: the picture tearing is what tells you the stare is about to
        // pay off — or that the thing is about to break and run.
        if session.presence.state == .seen {
            let held = Float(max(0, min(1, session.presence.gaze / EntityPresence.vanishGaze)))
            glitch = max(glitch, 0.12 + held * 0.5)
            dropout = max(dropout, 0.22 + held * 0.35)
        }

        lowBattery = Float(max(0, min(1, (30.0 - session.player.stamina) / 30.0))) * 0.35
    }
}
#endif
