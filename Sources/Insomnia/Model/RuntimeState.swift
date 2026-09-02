import Foundation

/// Everything Insomnia has changed on the machine and must undo.
/// Written to disk *before* each change is made and undone from disk, never
/// from memory (spec section 8 invariants).
struct RuntimeState: Codable, Equatable, Sendable {
    var sleepDisabledByUs: Bool = false
    var lowPowerSetByUs: Bool = false
    var frozenPids: [Int32] = []
    var dockerFrozen: Bool = false
    /// nil when mute is off or the lid is open.
    var savedOutputVolume: Float? = nil
    var savedMuted: Bool? = nil

    /// A state with nothing left to undo.
    static let clean = RuntimeState()

    /// True when at least one entry still needs undoing.
    var isDirty: Bool {
        sleepDisabledByUs || lowPowerSetByUs || !frozenPids.isEmpty || dockerFrozen
            || savedOutputVolume != nil || savedMuted != nil
    }

    // Tolerate missing keys so a state.json written by an older build, or by
    // backstop.sh, still decodes.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sleepDisabledByUs = try c.decodeIfPresent(Bool.self, forKey: .sleepDisabledByUs) ?? false
        lowPowerSetByUs = try c.decodeIfPresent(Bool.self, forKey: .lowPowerSetByUs) ?? false
        frozenPids = try c.decodeIfPresent([Int32].self, forKey: .frozenPids) ?? []
        dockerFrozen = try c.decodeIfPresent(Bool.self, forKey: .dockerFrozen) ?? false
        savedOutputVolume = try c.decodeIfPresent(Float.self, forKey: .savedOutputVolume)
        savedMuted = try c.decodeIfPresent(Bool.self, forKey: .savedMuted)
    }
}
