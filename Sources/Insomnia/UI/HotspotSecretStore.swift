import Foundation

/// Where the hotspot password lives. The system layer ships the Keychain
/// implementation (`insomnia-hotspot` in the login keychain); the settings
/// window only ever talks to this protocol.
protocol HotspotSecretStore: AnyObject, Sendable {
    func load() throws -> String?
    func save(_ password: String) throws
    func delete() throws
}

/// Placeholder that forgets the password when the app quits.
final class InMemoryHotspotSecretStore: HotspotSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var password: String?

    init() {}

    func load() throws -> String? { lock.withLock { password } }
    func save(_ password: String) throws { lock.withLock { self.password = password } }
    func delete() throws { lock.withLock { password = nil } }
}
