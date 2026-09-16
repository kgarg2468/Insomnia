import Foundation

/// Spec section 6 decision table (plus the section 4 lid row), as a pure
/// function plus a small driver.
enum FloorRules {
    /// Why Low Power Mode is being switched on. The strongest cause is
    /// named when several hold: thermal, then battery, then lid.
    enum LowPowerCause: Equatable, Sendable {
        case battery
        case thermal
        case lid
    }

    enum Action: Equatable, Sendable {
        case enableLowPower(LowPowerCause)
        case disableLowPower
        case endSession(EndReason)
    }

    /// Ordered actions for the current inputs.
    ///
    /// - battery below `endFloor` while not charging: end session
    /// - thermal `critical` (if `thermalRules`): end session
    /// - battery below `lowPowerFloor` while not charging, thermal
    ///   `serious` (if `thermalRules`), or lid closed (if
    ///   `lowPowerOnLidClose`, charging or not): Low Power Mode on
    /// - none of the above while we set Low Power Mode: Low Power Mode off
    ///   ("charger connected", "thermal back to nominal/fair", "lid opened")
    static func evaluate(
        percent: Int?,
        isCharging: Bool,
        thermal: ProcessInfo.ThermalState,
        lidClosed: Bool,
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
        let lidWantsLowPower = lidClosed && config.lowPowerOnLidClose
        let want = batteryWantsLowPower || thermalWantsLowPower || lidWantsLowPower
        if want, !lowPowerSetByUs {
            let cause: LowPowerCause = thermalWantsLowPower ? .thermal : batteryWantsLowPower ? .battery : .lid
            return [.enableLowPower(cause)]
        }
        if !want, lowPowerSetByUs { return [.disableLowPower] }
        return []
    }
}

/// Applies `FloorRules` through the session manager (journal first) and
/// posts the spec section 9 notifications. A lid-caused change is logged
/// but not announced: the user just closed or opened the lid.
@MainActor
struct FloorRuleDriver {
    weak var manager: SessionManager?
    let notifier: any Notifying
    /// Cause of the last enable this driver made, so the matching disable
    /// knows whether it was announced. Not journaled: after a relaunch the
    /// disable is announced as before.
    private let lastCause = LastCause()

    @MainActor
    private final class LastCause {
        var value: FloorRules.LowPowerCause?
    }

    init(manager: SessionManager, notifier: any Notifying) {
        self.manager = manager
        self.notifier = notifier
    }

    func run(percent: Int?, isCharging: Bool, thermal: ProcessInfo.ThermalState, lidClosed: Bool) async {
        guard let manager, manager.isActive, !Task.isCancelled else { return }
        let config = manager.config
        let actions = FloorRules.evaluate(
            percent: percent,
            isCharging: isCharging,
            thermal: thermal,
            lidClosed: lidClosed,
            lowPowerSetByUs: manager.state.lowPowerSetByUs,
            config: config
        )
        for action in actions {
            guard manager.isActive, !Task.isCancelled else { return }
            switch action {
            case let .enableLowPower(cause):
                guard await manager.setLowPower(true) else { continue }
                lastCause.value = cause
                guard manager.isActive, !Task.isCancelled else { return }
                switch cause {
                case .thermal:
                    notifier.post(title: "Low Power Mode on", body: "Thermal state is serious. Low Power Mode is on until it cools down.")
                case .battery:
                    notifier.post(title: "Low Power Mode on", body: "Battery at \(percent ?? 0)%, below the \(config.lowPowerFloor)% floor.")
                case .lid:
                    Log.info("low power mode on (lid closed)")
                }
            case .disableLowPower:
                if await manager.setLowPower(false) {
                    let cause = lastCause.value
                    lastCause.value = nil
                    guard manager.isActive, !Task.isCancelled else { return }
                    if cause == .lid {
                        Log.info("low power mode off (lid opened)")
                    } else {
                        notifier.post(title: "Low Power Mode off", body: isCharging ? "Charger connected." : "Back above the floor.")
                    }
                }
            case let .endSession(reason):
                await manager.end(reason: reason)
                guard manager.isActive, !Task.isCancelled else { return }
            }
        }
    }
}
