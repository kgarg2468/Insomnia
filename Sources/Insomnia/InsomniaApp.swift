import AppKit
import SwiftUI

/// Menu bar app. The status item is an `NSStatusItem` hosting SwiftUI (so
/// its width can animate, spec 11); the only SwiftUI scene is Settings.
@main
struct InsomniaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings {
            SettingsView(manager: delegate.manager, secrets: delegate.secrets)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = SessionManager.live()
    /// Replaced by the system layer's observer object once it lands.
    let status = PlaceholderStatus()
    /// Replaced by the Keychain store once the network layer lands.
    let secrets = InMemoryHotspotSecretStore()
    private var statusItem: StatusItemController?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run from `swift run` (the bundle has LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        Log.info("launched")
        statusItem = StatusItemController(manager: manager, status: status)
        Task { await manager.reconcile() }
    }

    /// Quitting always ends the session (spec 1). Terminate is deferred until
    /// sleep has been restored.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        terminating = true
        Task {
            await manager.end(reason: .quit)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
