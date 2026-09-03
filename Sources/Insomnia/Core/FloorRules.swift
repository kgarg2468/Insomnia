import Foundation

/// Spec section 6 decision table, as a pure function plus a small driver.
enum FloorRules {
    enum Action: Equatable, Sendable {
        case enableLowPower
        case disableLowPower
        case endSession(EndReason)
    }

    /// Ordered actions for the current inputs.
    ///
    /// - battery below `endFloor` while not charging: end session
    /// - thermal `critical` (if `thermalRules`): end session
    /// - battery below `lowPowerFloor` while not charging, or thermal
    ///   `serious` (if `thermalRules`): Low Power Mode on
    /// - none of the above while we set Low Power Mode: Low Power Mode off
    ///   ("charger connected" and "thermal back to nominal/fair")
    static func evaluate(
        percent: Int?,
        isCharging: Bool,
        thermal: ProcessInfo.ThermalState,
        lowPowerSetByUs: Bool,
        config: Config
    ) -> [Action] {
        let onBattery = !isCharging
        if let p = percent, onBattery, p < config.endFloor {
            return [.endSession(.batteryFloor)]
        }
        if config.thermalRules, thermal == .critical {
            return [.endSession(.thermalCritical)]
        }
        let batteryWantsLowPower = percent.map { onBattery && $0 < config.lowPowerFloor } ?? false
        let thermalWantsLowPower = config.thermalRules && thermal == .serious
        let want = batteryWantsLowPower || thermalWantsLowPower
        if want, !lowPowerSetByUs { return [.enableLowPower] }
        if !want, lowPowerSetByUs { return [.disableLowPower] }
        return []
    }
}

/// Applies `FloorRules` through the session manager (journal first) and
/// posts the spec section 9 notifications.
@MainActor
struct FloorRuleDriver {
    weak var manager: SessionManager?
    let notifier: any Notifying

    init(manager: SessionManager, notifier: any Notifying) {
        self.manager = manager
        self.notifier = notifier
    }

    func run(percent: Int?, isCharging: Bool, thermal: ProcessInfo.ThermalState) async {
        guard let manager, manager.isActive, !Task.isCancelled else { return }
        let config = manager.config
        let actions = FloorRules.evaluate(
            percent: percent,
            isCharging: isCharging,
            thermal: thermal,
            lowPowerSetByUs: manager.state.lowPowerSetByUs,
            config: config
        )
        for action in actions {
            guard manager.isActive, !Task.isCancelled else { return }
            switch action {
            case .enableLowPower:
                let thermalCause = config.thermalRules && thermal == .serious
                guard await manager.setLowPower(true) else { continue }
                guard manager.isActive, !Task.isCancelled else { return }
                if thermalCause {
                    notifier.post(title: "Low Power Mode on", body: "Thermal state is serious. Low Power Mode is on until it cools down.")
                } else {
                    notifier.post(title: "Low Power Mode on", body: "Battery at \(percent ?? 0)%, below the \(config.lowPowerFloor)% floor.")
                }
            case .disableLowPower:
                if await manager.setLowPower(false) {
                    guard manager.isActive, !Task.isCancelled else { return }
                    notifier.post(title: "Low Power Mode off", body: isCharging ? "Charger connected." : "Back above the floor.")
                }
            case let .endSession(reason):
                await manager.end(reason: reason)
                guard manager.isActive, !Task.isCancelled else { return }
            }
        }
    }
}
