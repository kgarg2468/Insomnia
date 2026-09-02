import Foundation
import IOKit
import IOKit.ps

/// Spec section 6 event sources: `IOPSNotificationCreateRunLoopSource` for
/// battery changes and `ProcessInfo.thermalStateDidChangeNotification`.
/// Watts are read from `AppleSmartBattery` only when `instantWatts()` is
/// called (the popover opening), never polled.
@MainActor
final class PowerMonitor {
    private(set) var percent: Int?
    /// True when on AC power or actively charging. The floor rules treat
    /// "charger connected" as the undo condition (spec section 6).
    private(set) var isCharging: Bool = false
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    /// Called on the main actor after any battery or thermal change.
    var onChange: (() -> Void)?

    private var source: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?

    init() {}

    func start() {
        guard source == nil, thermalObserver == nil else { return }
        refreshBattery()
        thermalState = ProcessInfo.processInfo.thermalState

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let s = IOPSNotificationCreateRunLoopSource(Self.callback, refcon)?.takeRetainedValue() {
            source = s
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        } else {
            Log.error("power monitor: IOPSNotificationCreateRunLoopSource failed")
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleThermal() }
        }
        Log.info("power monitor started (battery \(percent.map(String.init) ?? "n/a")%, \(isCharging ? "charging" : "on battery"), thermal \(Self.name(thermalState)))")
    }

    func stop() {
        if let s = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            source = nil
        }
        if let o = thermalObserver {
            NotificationCenter.default.removeObserver(o)
            thermalObserver = nil
        }
    }

    /// Re-read the power source list synchronously. Cheap; used by the
    /// popover's on-demand refresh.
    func refreshBattery() {
        let snap = Self.readBattery()
        percent = snap.percent
        isCharging = snap.charging
    }

    /// Signed watts: negative while discharging, positive while charging.
    /// nil when there is no AppleSmartBattery (desktop) or a key is missing.
    nonisolated func instantWatts() -> Double? {
        Self.readInstantWatts()
    }

    static func name(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    // MARK: Reads

    nonisolated static func readBattery() -> (percent: Int?, charging: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, false) }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int
            let max = desc[kIOPSMaxCapacityKey] as? Int
            var percent: Int?
            if let current, let max, max > 0 {
                percent = Int((Double(current) / Double(max) * 100).rounded())
            }
            let onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            return (percent, onAC || charging)
        }
        return (nil, false)
    }

    nonisolated static func readInstantWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int64? {
            guard let v = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
            return (v as? NSNumber)?.int64Value
        }
        guard var amperage = int("InstantAmperage"), let voltage = int("Voltage") else { return nil }
        // Some firmware reports a negative (discharging) current as a 32-bit
        // two's complement value stored in a wider integer.
        if amperage > Int64(Int32.max), amperage <= Int64(UInt32.max) {
            amperage -= Int64(UInt32.max) + 1
        }
        return Double(amperage) * Double(voltage) / 1_000_000
    }

    // MARK: Private

    private static let callback: IOPowerSourceCallbackType = { refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.handleBattery() }
    }

    private func handleBattery() {
        let before = (percent, isCharging)
        refreshBattery()
        if before != (percent, isCharging) {
            Log.info("battery \(percent.map(String.init) ?? "n/a")% \(isCharging ? "charging" : "on battery")")
            onChange?()
        }
    }

    private func handleThermal() {
        let now = ProcessInfo.processInfo.thermalState
        guard now != thermalState else { return }
        thermalState = now
        Log.info("thermal state \(Self.name(now))")
        onChange?()
    }
}
