import Foundation
import UserNotifications

protocol Notifying: Sendable {
    func post(title: String, body: String)
}

/// Records posts; for tests and for SessionManager's default.
final class RecordingNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [(title: String, body: String)] = []
    var posts: [(title: String, body: String)] { lock.withLock { _posts } }
    func post(title: String, body: String) { lock.withLock { _posts.append((title, body)) } }
}

/// UNUserNotificationCenter wrapper. `UNUserNotificationCenter.current()`
/// raises an Objective-C exception when the process is not an app bundle
/// (`swift run`, tests), which Swift cannot catch, so availability is checked
/// up front and everything degrades to a log line.
final class Notifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var authorizationRequested = false
    private var authorized = false
    let available: Bool

    init() {
        available = Self.runningInsideAppBundle()
        if !available {
            Log.info("notifications unavailable outside an app bundle; will log instead")
        }
    }

    static func runningInsideAppBundle() -> Bool {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier != nil else { return false }
        guard bundle.bundleURL.pathExtension == "app" else { return false }
        return bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL"
    }

    func requestAuthorizationIfNeeded() {
        guard available else { return }
        let first = lock.withLock { () -> Bool in
            if authorizationRequested { return false }
            authorizationRequested = true
            return true
        }
        guard first else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Log.error("notification authorization failed: \(error.localizedDescription)")
            }
            self?.lock.withLock { self?.authorized = granted }
            Log.info("notification authorization \(granted ? "granted" : "denied")")
        }
    }

    func post(title: String, body: String) {
        Log.info("notify: \(title) - \(body)")
        guard available else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("notification post failed: \(error.localizedDescription)")
            }
        }
    }
}
