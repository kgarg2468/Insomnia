import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Failure in the display or keyboard backlight layer. `what` is the whole
/// story: which framework, symbol, class or call was missing or refused.
struct DisplayPowerError: Error, LocalizedError, Sendable {
    let what: String

    var errorDescription: String? { what }
}

/// Built-in display brightness and power (spec section 4). With `pmset -a
/// disablesleep 1` macOS never turns the panel off on lid close (that only
/// happens on the system-sleep path), so lid close saves the brightness and
/// sets it to 0, and lid open puts it back.
protocol DisplayDimming: Sendable {
    /// User brightness of the built-in display, 0...1.
    func readBrightness() throws -> Float
    func setBrightness(_ value: Float) throws
    /// Ask the display to sleep now. macOS ignores it while any process holds a display assertion.
    func requestSleep() throws
    /// Declare local user activity so a sleeping display wakes. Best effort, never throws.
    func wake()
    /// Whether the built-in display is asleep (`CGDisplayIsAsleep`). While it
    /// is, `readBrightness()` returns the idle-dim value, not the user's.
    /// No display: false.
    func isAsleep() -> Bool
}

/// Built-in keyboard backlight. Setting the display to 0 does not switch it
/// off; it has to be set on its own.
protocol KeyboardBacklighting: Sendable {
    /// nil when there is no built-in keyboard backlight.
    func readBrightness() throws -> Float?
    func setBrightness(_ value: Float) throws
    /// Whether macOS is holding the backlight down itself: suppressed by
    /// display sleep (reads as 0) or idle-dimmed. A value read then is not
    /// the user's. No keyboard: false.
    func isSuppressedOrDimmed() -> Bool
}

/// Pure helpers shared by the live implementations, tested without the
/// private frameworks.
enum DisplayPower {
    static func clamped(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    /// The built-in panel among the online displays. With an external
    /// monitor in clamshell mode the main display is not the panel.
    static func builtInDisplay(
        among ids: [CGDirectDisplayID],
        isBuiltIn: (CGDirectDisplayID) -> Bool,
        fallback: CGDirectDisplayID
    ) -> CGDirectDisplayID {
        ids.first(where: isBuiltIn) ?? fallback
    }

    static func builtInKeyboards(among ids: [UInt64], isBuiltIn: (UInt64) -> Bool) -> [UInt64] {
        ids.filter(isBuiltIn)
    }
}

/// Does nothing; the default for SessionManager, AppServices and LidActions
/// so tests and non-display paths need neither private framework. Reading
/// throws, so nothing is journaled and nothing is set.
struct NoopDisplayDimmer: DisplayDimming {
    func readBrightness() throws -> Float { throw DisplayPowerError(what: "no display control") }
    func setBrightness(_ value: Float) throws {}
    func requestSleep() throws {}
    func wake() {}
    func isAsleep() -> Bool { false }
}

/// Does nothing; reads as "no built-in keyboard backlight".
struct NoopKeyboardBacklight: KeyboardBacklighting {
    func readBrightness() throws -> Float? { nil }
    func setBrightness(_ value: Float) throws {}
    func isSuppressedOrDimmed() -> Bool { false }
}

/// Private DisplayServices.framework, measured on macOS 26 (see
/// docs/release-validation.md): Get/SetBrightness take effect at once
/// whether the display is awake, asleep or held by a display assertion.
/// Symbols are resolved once, lazily, under a lock; a macOS that drops one
/// makes every call throw, so the lid close logs and skips rather than
/// crashing.
final class DisplayServicesDimmer: DisplayDimming, @unchecked Sendable {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    private struct Symbols {
        let get: GetBrightness
        let set: SetBrightness
        let canChange: CanChangeBrightness
    }

    private static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private let lock = NSLock()
    private var resolved: Result<Symbols, DisplayPowerError>?

    init() {}

    func readBrightness() throws -> Float {
        let symbols = try self.symbols()
        let display = try changeableDisplay(symbols)
        var value: Float = 0
        let rc = symbols.get(display, &value)
        guard rc == 0 else { throw DisplayPowerError(what: "DisplayServicesGetBrightness failed (\(rc))") }
        return value
    }

    func setBrightness(_ value: Float) throws {
        let symbols = try self.symbols()
        let display = try changeableDisplay(symbols)
        let rc = symbols.set(display, DisplayPower.clamped(value))
        guard rc == 0 else { throw DisplayPowerError(what: "DisplayServicesSetBrightness failed (\(rc))") }
    }

    /// What `pmset displaysleepnow` does. Honoured only when no process
    /// holds a PreventUserIdleDisplaySleep assertion, and deferred by powerd
    /// for ~30 s after any wake.
    func requestSleep() throws {
        let wrangler = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        guard wrangler != 0 else { throw DisplayPowerError(what: "IODisplayWrangler not found") }
        defer { IOObjectRelease(wrangler) }
        let kr = IORegistryEntrySetCFProperty(wrangler, "IORequestIdle" as CFString, kCFBooleanTrue)
        guard kr == KERN_SUCCESS else { throw DisplayPowerError(what: "IORequestIdle refused (\(kr))") }
    }

    func wake() {
        var id: IOPMAssertionID = 0
        let kr = IOPMAssertionDeclareUserActivity("Insomnia lid open" as CFString, kIOPMUserActiveLocal, &id)
        if kr != kIOReturnSuccess {
            Log.error("display wake failed: IOPMAssertionDeclareUserActivity returned \(kr)")
        }
    }

    /// Public CoreGraphics; needs no private symbol. A missing display
    /// (`kCGNullDirectDisplay`) reads as awake.
    func isAsleep() -> Bool {
        CGDisplayIsAsleep(Self.builtInDisplayID()) != 0
    }

    // MARK: Private

    private func symbols() throws -> Symbols {
        try lock.withLock {
            if let resolved { return try resolved.get() }
            let result = Self.resolve()
            resolved = result
            return try result.get()
        }
    }

    private static func resolve() -> Result<Symbols, DisplayPowerError> {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            return .failure(DisplayPowerError(what: "DisplayServices.framework could not be loaded"))
        }
        func symbol<T>(_ name: String) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw DisplayPowerError(what: "DisplayServices.framework has no \(name)")
            }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            return .success(Symbols(
                get: try symbol("DisplayServicesGetBrightness"),
                set: try symbol("DisplayServicesSetBrightness"),
                canChange: try symbol("DisplayServicesCanChangeBrightness")
            ))
        } catch {
            return .failure(error as? DisplayPowerError ?? DisplayPowerError(what: error.localizedDescription))
        }
    }

    private func changeableDisplay(_ symbols: Symbols) throws -> CGDirectDisplayID {
        let display = Self.builtInDisplayID()
        guard symbols.canChange(display) else {
            throw DisplayPowerError(what: "display \(display) cannot change brightness")
        }
        return display
    }

    private static func builtInDisplayID() -> CGDirectDisplayID {
        let main = CGMainDisplayID()
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return main }
        return DisplayPower.builtInDisplay(
            among: Array(ids.prefix(Int(count))),
            isBuiltIn: { CGDisplayIsBuiltin($0) != 0 },
            fallback: main
        )
    }
}

/// Selectors of the private CoreBrightness `KeyboardBrightnessClient`,
/// verified on macOS 26. The instance is checked with `responds(to:)` for
/// each of the first four before it is used, so a renamed method in a future
/// macOS throws instead of raising an unrecognized selector. The two
/// suppressed/dimmed queries are optional: each is checked at call time and
/// a missing one reads as false.
@objc protocol KeyboardBrightnessClientBridge: NSObjectProtocol {
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> NSArray?
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ id: UInt64) -> Bool
    @objc(brightnessForKeyboard:) func brightness(forKeyboard id: UInt64) -> Float
    @objc(setBrightness:forKeyboard:) func setBrightness(_ value: Float, forKeyboard id: UInt64) -> Bool
    /// True while display sleep holds the backlight off; reads then are 0.
    @objc(isBacklightSuppressedOnKeyboard:) func isBacklightSuppressed(onKeyboard id: UInt64) -> Bool
    /// True while the keyboard's own idle dim is in effect.
    @objc(isBacklightDimmedOnKeyboard:) func isBacklightDimmed(onKeyboard id: UInt64) -> Bool
}

/// Private CoreBrightness.framework. A write made while the display is
/// asleep reads back 0 but is remembered and applied on the next wake.
final class CoreBrightnessKeyboardBacklight: KeyboardBacklighting, @unchecked Sendable {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    private static let className = "KeyboardBrightnessClient"
    private static let selectors = [
        "copyKeyboardBacklightIDs", "isKeyboardBuiltIn:", "brightnessForKeyboard:", "setBrightness:forKeyboard:",
    ]
    private let lock = NSLock()
    private var resolved: Result<any KeyboardBrightnessClientBridge, DisplayPowerError>?

    init() {}

    func readBrightness() throws -> Float? {
        let client = try self.client()
        guard let first = Self.builtInIDs(client).first else { return nil }
        return client.brightness(forKeyboard: first)
    }

    func setBrightness(_ value: Float) throws {
        let client = try self.client()
        let ids = Self.builtInIDs(client)
        guard !ids.isEmpty else { throw DisplayPowerError(what: "no built-in keyboard backlight") }
        for id in ids where !client.setBrightness(DisplayPower.clamped(value), forKeyboard: id) {
            throw DisplayPowerError(what: "setBrightness:forKeyboard: refused for keyboard \(id)")
        }
    }

    /// Each query is behind its own `responds(to:)`: a macOS that drops one
    /// reads as "not held down", which only costs a less trusted sample.
    func isSuppressedOrDimmed() -> Bool {
        guard let client = try? self.client(), let first = Self.builtInIDs(client).first else { return false }
        let suppressed = client.responds(to: NSSelectorFromString("isBacklightSuppressedOnKeyboard:"))
            && client.isBacklightSuppressed(onKeyboard: first)
        let dimmed = client.responds(to: NSSelectorFromString("isBacklightDimmedOnKeyboard:"))
            && client.isBacklightDimmed(onKeyboard: first)
        return suppressed || dimmed
    }

    // MARK: Private

    private static func builtInIDs(_ client: any KeyboardBrightnessClientBridge) -> [UInt64] {
        let ids = (client.copyKeyboardBacklightIDs() as? [NSNumber])?.map(\.uint64Value) ?? []
        return DisplayPower.builtInKeyboards(among: ids, isBuiltIn: client.isKeyboardBuiltIn)
    }

    private func client() throws -> any KeyboardBrightnessClientBridge {
        try lock.withLock {
            if let resolved { return try resolved.get() }
            let result = Self.resolve()
            resolved = result
            return try result.get()
        }
    }

    private static func resolve() -> Result<any KeyboardBrightnessClientBridge, DisplayPowerError> {
        guard dlopen(frameworkPath, RTLD_LAZY) != nil else {
            return .failure(DisplayPowerError(what: "CoreBrightness.framework could not be loaded"))
        }
        guard let cls = NSClassFromString(className) as? NSObject.Type else {
            return .failure(DisplayPowerError(what: "CoreBrightness.framework has no \(className)"))
        }
        let instance = cls.init()
        for name in selectors where !instance.responds(to: NSSelectorFromString(name)) {
            return .failure(DisplayPowerError(what: "\(className) does not respond to \(name)"))
        }
        return .success(unsafeBitCast(instance, to: (any KeyboardBrightnessClientBridge).self))
    }
}
