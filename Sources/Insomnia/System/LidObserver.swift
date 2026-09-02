import Foundation
import IOKit

/// Spec section 3: IOKit interest notification on `IOPMrootDomain`. The
/// kernel wakes us on a clamshell change; between events nothing runs.
/// A change is delivered only if the state is still the same 2 s later.
@MainActor
final class LidObserver {
    nonisolated static let debounce: TimeInterval = 2
    nonisolated static let clamshellKey = "AppleClamshellState"

    /// Called on the main actor after the debounce, with `true` for closed.
    var onChange: ((Bool) -> Void)?

    /// Last delivered state, refreshed from the registry when read.
    var isClosed: Bool {
        Self.readClamshellState() ?? lastDelivered
    }

    private var lastDelivered: Bool = false
    private var pending: Bool?
    private var debounceTimer: Timer?

    private var port: IONotificationPortRef?
    private var service: io_service_t = 0
    private var notification: io_object_t = 0

    init() {}

    /// Pure registry read: true = closed, false = open, nil = unavailable
    /// (no IOPMrootDomain or no clamshell, e.g. a desktop).
    nonisolated static func readClamshellState() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, clamshellKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue)
    }

    func start() {
        guard port == nil else { return }
        lastDelivered = Self.readClamshellState() ?? false
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            Log.error("lid observer: IOPMrootDomain not found")
            return
        }
        guard let p = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.error("lid observer: IONotificationPortCreate failed")
            IOObjectRelease(service)
            service = 0
            return
        }
        port = p
        let source = IONotificationPortGetRunLoopSource(p).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddInterestNotification(p, service, kIOGeneralInterest, Self.callback, refcon, &notification)
        guard kr == KERN_SUCCESS else {
            Log.error("lid observer: IOServiceAddInterestNotification failed (\(kr))")
            stop()
            return
        }
        Log.info("lid observer started (lid \(lastDelivered ? "closed" : "open"))")
    }

    func stop() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        pending = nil
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if let p = port {
            let source = IONotificationPortGetRunLoopSource(p).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            IONotificationPortDestroy(p)
            port = nil
        }
        if service != 0 {
            IOObjectRelease(service)
            service = 0
        }
    }

    // MARK: Private

    private static let callback: IOServiceInterestCallback = { refcon, _, _, _ in
        guard let refcon else { return }
        let observer = Unmanaged<LidObserver>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { observer.handleInterest() }
    }

    /// Any message from IOPMrootDomain: re-read the registry and debounce.
    private func handleInterest() {
        guard let now = Self.readClamshellState() else { return }
        guard now != lastDelivered else {
            // Flapped back to the delivered state; drop the pending change.
            if pending != nil {
                pending = nil
                debounceTimer?.invalidate()
                debounceTimer = nil
            }
            return
        }
        guard pending != now else { return }
        pending = now
        debounceTimer?.invalidate()
        let timer = Timer(timeInterval: Self.debounce, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.settle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    private func settle() {
        debounceTimer = nil
        guard let candidate = pending else { return }
        pending = nil
        guard let now = Self.readClamshellState(), now == candidate, now != lastDelivered else {
            Log.info("lid observer: change flapped within \(Int(Self.debounce)) s, ignored")
            return
        }
        lastDelivered = now
        Log.info("lid \(now ? "closed" : "open")")
        onChange?(now)
    }
}
