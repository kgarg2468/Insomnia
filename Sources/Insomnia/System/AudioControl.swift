import AudioToolbox
import CoreAudio
import Foundation

/// Default output device volume and mute, so lid close can mute and lid open
/// can restore exactly (spec section 4).
protocol AudioControlling: Sendable {
    func read() throws -> (volume: Float, muted: Bool)
    func apply(volume: Float, muted: Bool) throws
    func mute() throws
}

struct AudioControlError: Error, LocalizedError, Sendable {
    let what: String
    let status: OSStatus

    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

/// Does nothing; the default for SessionManager so tests and non-audio
/// paths need no CoreAudio.
struct NoopAudioControl: AudioControlling {
    func read() throws -> (volume: Float, muted: Bool) { (1, false) }
    func apply(volume: Float, muted: Bool) throws {}
    func mute() throws {}
}

/// CoreAudio implementation over the current default output device.
struct CoreAudioControl: AudioControlling {
    func read() throws -> (volume: Float, muted: Bool) {
        let device = try defaultOutputDevice()
        var volume: Float32 = 0
        try get(device, Self.volumeAddress, &volume, "read volume")
        var muted: UInt32 = 0
        try get(device, Self.muteAddress, &muted, "read mute")
        return (Float(volume), muted != 0)
    }

    func apply(volume: Float, muted: Bool) throws {
        let device = try defaultOutputDevice()
        var v = Float32(min(max(volume, 0), 1))
        try set(device, Self.volumeAddress, &v, "set volume")
        var m: UInt32 = muted ? 1 : 0
        try set(device, Self.muteAddress, &m, "set mute")
    }

    func mute() throws {
        let device = try defaultOutputDevice()
        var m: UInt32 = 1
        try set(device, Self.muteAddress, &m, "mute")
    }

    // MARK: CoreAudio plumbing

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw AudioControlError(what: "default output device", status: status)
        }
        return device
    }

    private func get<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T, _ what: String) throws {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr else { throw AudioControlError(what: what, status: status) }
    }

    private func set<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T, _ what: String) throws {
        var addr = address
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &value) { ptr in
            AudioObjectSetPropertyData(device, &addr, 0, nil, size, UnsafeRawPointer(ptr))
        }
        guard status == noErr else { throw AudioControlError(what: what, status: status) }
    }
}
