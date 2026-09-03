import SwiftUI

enum WiFiStatusName {
    static func display(ssid: String?, locationAuthorized: Bool) -> String? {
        if let ssid, !ssid.isEmpty { return ssid }
        return locationAuthorized ? nil : "on (name hidden until Location is allowed)"
    }
}

/// Popover shown when the countdown is clicked.
struct SessionPopoverView: View {
    let manager: SessionManager
    let status: any StatusSource
    /// Read once when the popover opens (spec: never polled).
    let watts: Double?
    let onExtend: (TimeInterval) -> Void
    let onCustomExtend: () -> Void
    let onEnd: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = manager.session {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ends \(s.endsAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(subtitle(for: s))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .animation(Motion.base(), value: s.endsAt)

                HStack(spacing: 6) {
                    Chip(title: "+30m") { onExtend(30 * 60) }
                    Chip(title: "+1h") { onExtend(3600) }
                    Chip(title: "+4h") { onExtend(4 * 3600) }
                    Chip(title: "Custom…", action: onCustomExtend)
                    Spacer(minLength: 0)
                }

                Button(role: .destructive, action: onEnd) {
                    Label("End now", systemImage: "moon.zzz.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Text("No active session")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Divider()

            statusBlock

            if let err = manager.lastError {
                ErrorRow(message: err)
            }

            Divider()

            HStack {
                Button("Settings…") {
                    onSettings()
                    openSettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                Spacer()
                Button("Quit Insomnia", action: onQuit)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func subtitle(for s: Session) -> String {
        var parts = ["\(manager.remainingText.isEmpty ? SessionMath.formatRemaining(s.remaining(at: Date())) : manager.remainingText) left"]
        if !s.extensions.isEmpty {
            parts.append("extended \(s.extensions.count)\u{00D7}")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let held = SleepHeldLine.line(sessionActive: manager.isActive, sleepHeld: manager.state.sleepDisabledByUs) {
                HStack(spacing: 5) {
                    Image(systemName: held.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(held.isWarning ? .orange : .green)
                    Text(held.text)
                        .foregroundStyle(held.isWarning ? .orange : .primary)
                }
                .font(.system(size: 11, weight: .medium))
                .accessibilityElement(children: .combine)
            }

            Text(StatusLines.machine(
                lidClosed: status.lidClosed,
                watts: watts,
                wifiSSID: WiFiStatusName.display(
                    ssid: status.wifiSSID,
                    locationAuthorized: (status as? LiveStatusSource)?.locationPermission.isAuthorized ?? true
                ),
                batteryPercent: status.batteryPercent,
                isCharging: status.isCharging
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if let actions = StatusLines.actions(frozenCount: status.frozenCount, dockerPaused: status.dockerPaused, lastGap: status.lastGap) {
                Text(actions)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let warning = StatusLines.throttleWarning(status.throttledBrowsers) {
                HStack(spacing: 8) {
                    Text(warning)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("Relaunch unthrottled") {
                        for name in status.throttledBrowsers {
                            status.relaunchUnthrottled(name)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

/// The one line that says whether sleep is really held, read from the
/// journal (`RuntimeState.sleepDisabledByUs`) rather than inferred from the
/// presence of a session. Pure so it can be tested.
enum SleepHeldLine {
    struct Line: Equatable {
        let text: String
        let isWarning: Bool
    }

    static func line(sessionActive: Bool, sleepHeld: Bool) -> Line? {
        switch (sessionActive, sleepHeld) {
        case (true, true):
            Line(text: "Sleep held \u{2014} safe to close the lid", isWarning: false)
        case (true, false):
            Line(text: "Sleep is not held \u{2014} this session is not keeping the Mac awake", isWarning: true)
        case (false, true):
            Line(text: "Sleep still held with no session", isWarning: true)
        case (false, false):
            nil
        }
    }
}
