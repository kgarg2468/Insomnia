import AppKit
import SwiftUI

// PR3 replaces this file with the animated inline time-entry UI (spec 11).
// This is a plain placeholder menu so the core can be exercised.

@main
struct InsomniaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(manager: delegate.manager)
        } label: {
            MenuLabel(manager: delegate.manager)
        }
    }
}

struct MenuLabel: View {
    let manager: SessionManager

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: manager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
            if manager.isActive {
                Text(manager.remainingText)
            }
        }
    }
}

struct MenuContent: View {
    let manager: SessionManager

    var body: some View {
        if let s = manager.session {
            Text("Ends \(s.endsAt.formatted(date: .abbreviated, time: .shortened))")
            Button("Extend +1h") { Task { await manager.extend(by: 3600) } }
            Button("End now") { Task { await manager.end(reason: .user) } }
        } else {
            Button("Start 30m") { Task { await manager.start(duration: 30 * 60) } }
            Button("Start 1h") { Task { await manager.start(duration: 3600) } }
            Button("Start 4h") { Task { await manager.start(duration: 4 * 3600) } }
            Button("Start 8h") { Task { await manager.start(duration: 8 * 3600) } }
        }
        if let err = manager.lastError {
            Divider()
            Text(err).foregroundStyle(.secondary)
        }
        Divider()
        Button("Quit Insomnia") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = SessionManager.live()
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launched")
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
