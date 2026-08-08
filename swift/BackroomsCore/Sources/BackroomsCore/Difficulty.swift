/// A run's difficulty — the web build's `DIFFS` table.
///
/// `EntityDifficulty` already carries the four AI multipliers and is threaded
/// through `EntityPresence`; what it deliberately does not carry is the rules
/// that are about the *run* rather than the creature — whether the exit beacon
/// sounds before you have found the door, and whether tapes advertise
/// themselves. Those live here so the entity type stays about the entity.
///
/// SIMPLE exists for the same reason it does in the web build: the floors are
/// learnable and a change is testable end to end without dying to a hunt you
/// did not schedule.
public struct Difficulty: Sendable, Equatable {

    /// Stable identifier, for persisting the choice.
    public let id: String
    /// Shown on the menu button.
    public let label: String
    /// One line under the label, so the choice is legible before it is made.
    public let blurb: String
    /// The multipliers `EntityPresence` consumes.
    public let entity: EntityDifficulty
    /// Sonar on the exit even before the door reveals itself.
    public let beaconAlways: Bool
    /// A bearing and an on-screen arrow to the nearest tape still out there.
    public let tapeHints: Bool

    public init(id: String, label: String, blurb: String, entity: EntityDifficulty,
                beaconAlways: Bool, tapeHints: Bool) {
        self.id = id
        self.label = label
        self.blurb = blurb
        self.entity = entity
        self.beaconAlways = beaconAlways
        self.tapeHints = tapeHints
    }

    /// The game as designed. Multipliers are all 1.0, so this is exactly the
    /// behaviour every fixture test was recorded against.
    public static let standard = Difficulty(
        id: "standard", label: "STANDARD",
        blurb: "The tape as it was found.",
        entity: .standard, beaconAlways: false, tapeHints: false)

    /// `hunt:3.2, sight:2.2, speed:0.60, huntTime:0.45, creep:0.4` — the web
    /// build's SIMPLE row, unchanged.
    public static let simple = Difficulty(
        id: "simple", label: "SIMPLE",
        blurb: "Rarer hunts, slower thing, tapes marked.",
        entity: .simple, beaconAlways: true, tapeHints: true)

    public static let all: [Difficulty] = [.standard, .simple]

    public static func named(_ id: String) -> Difficulty {
        all.first { $0.id == id } ?? .standard
    }
}
