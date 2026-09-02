import Foundation
import Observation

/// Live machine status shown in the session popover. The system layer
/// (lid, battery, network, freeze, browser throttle) provides the real
/// object; the UI only ever talks to this protocol.
@MainActor
protocol StatusSource: AnyObject, Observable {
    var lidClosed: Bool { get }
    var batteryPercent: Int? { get }
    var isCharging: Bool { get }
    var wifiSSID: String? { get }
    /// Length of the most recent network outage, nil if none this session.
    var lastGap: TimeInterval? { get }
    var frozenCount: Int { get }
    var dockerPaused: Bool { get }
    /// Display names of browsers running without the occlusion flags.
    var throttledBrowsers: [String] { get }

    /// Called when the popover opens; observers refresh anything not pushed.
    func refreshOnDemand()
    /// Battery draw read on demand from AppleSmartBattery. Never polled.
    func instantWatts() -> Double?
    func relaunchUnthrottled(_ name: String)
}

/// Stand-in until the system layer is plugged in. Reports nothing.
@MainActor
@Observable
final class PlaceholderStatus: StatusSource {
    var lidClosed: Bool = false
    var batteryPercent: Int? = nil
    var isCharging: Bool = false
    var wifiSSID: String? = nil
    var lastGap: TimeInterval? = nil
    var frozenCount: Int = 0
    var dockerPaused: Bool = false
    var throttledBrowsers: [String] = []

    init() {}

    func refreshOnDemand() {}
    func instantWatts() -> Double? { nil }
    func relaunchUnthrottled(_ name: String) {}
}

/// Pure formatting for the popover's status block, kept out of the views so
/// it can be tested.
enum StatusLines {
    /// "Lid: closed · 4.1 W · Wi-Fi: iPhone". Unknown parts are omitted.
    static func machine(lidClosed: Bool, watts: Double?, wifiSSID: String?, batteryPercent: Int?, isCharging: Bool) -> String {
        var parts: [String] = ["Lid: \(lidClosed ? "closed" : "open")"]
        if let w = watts {
            parts.append(String(format: "%.1f W", w))
        }
        if let p = batteryPercent {
            parts.append(isCharging ? "\(p)% charging" : "\(p)%")
        }
        if let ssid = wifiSSID, !ssid.isEmpty {
            parts.append("Wi-Fi: \(ssid)")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "3 apps frozen · Docker paused", or nil when nothing is held.
    static func actions(frozenCount: Int, dockerPaused: Bool, lastGap: TimeInterval?) -> String? {
        var parts: [String] = []
        if frozenCount > 0 {
            parts.append(frozenCount == 1 ? "1 app frozen" : "\(frozenCount) apps frozen")
        }
        if dockerPaused {
            parts.append("Docker paused")
        }
        if let gap = lastGap, gap > 0 {
            parts.append("last gap \(Int(gap.rounded()))s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// "⚠ Chrome is throttled" / "⚠ Chrome and Arc are throttled".
    static func throttleWarning(_ browsers: [String]) -> String? {
        guard !browsers.isEmpty else { return nil }
        let names: String
        switch browsers.count {
        case 1: names = browsers[0]
        case 2: names = "\(browsers[0]) and \(browsers[1])"
        default: names = browsers.dropLast().joined(separator: ", ") + ", and " + browsers.last!
        }
        return "\u{26A0} \(names) \(browsers.count == 1 ? "is" : "are") throttled"
    }
}
