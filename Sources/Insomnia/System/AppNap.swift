import CoreFoundation
import Foundation

/// Spec section 5: `NSAppSleepDisabled = YES` for every agent app so App Nap
/// never throttles it. Written to each app's own preferences domain, exactly
/// like `defaults write <bundle> NSAppSleepDisabled -bool YES`. Persistent
/// by design; never unset (spec open decisions).
enum AppNap {
    static let key = "NSAppSleepDisabled"

    @discardableResult
    static func disable(for bundleIds: [String]) -> [String] {
        var done: [String] = []
        for id in bundleIds where !id.isEmpty {
            let app = id as CFString
            CFPreferencesSetAppValue(key as CFString, kCFBooleanTrue, app)
            if CFPreferencesAppSynchronize(app) {
                done.append(id)
            } else {
                Log.error("app nap: could not write \(key) for \(id)")
            }
        }
        if !done.isEmpty {
            Log.info("app nap disabled for \(done.count) app(s)")
        }
        return done
    }
}
