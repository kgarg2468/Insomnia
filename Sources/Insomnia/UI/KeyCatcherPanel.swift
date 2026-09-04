import AppKit

/// The invisible key window that exists only while the duration pills are open.
///
/// The pills read the keyboard through a *local* event monitor, which only
/// sees what AppKit routes to this app, and AppKit routes key events to the
/// key window. Insomnia is an `.accessory` app whose whole interface lives in
/// the status bar, so without this it has no window at all: `NSApp.activate`
/// makes it active but leaves `keyWindow` nil, and the digits go to whichever
/// app the user was in.
///
/// It has to be an `NSPanel`: `restorePreviousApp()` stands down when a
/// visible non-panel key window is up (the Settings window), and this one must
/// not look like that.
final class KeyCatcherPanel: NSPanel {
    /// A borderless window refuses key status by default.
    override var canBecomeKey: Bool { true }

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // Never take a click: the status item and the global monitor own the
        // mouse while the pills are open.
        ignoresMouseEvents = true
        level = .statusBar
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    /// Park the panel on the status item, so it comes up on the screen and the
    /// space the pills are on rather than wherever the window server last put
    /// a 1×1 window.
    func move(toStatusButton button: NSStatusBarButton) {
        guard let anchor = button.window?.convertToScreen(button.bounds) else { return }
        setFrameOrigin(NSPoint(x: anchor.midX, y: anchor.minY))
    }
}
