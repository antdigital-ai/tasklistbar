import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Foundation

@MainActor
final class VolumeMonitor: ObservableObject {
    @Published private(set) var level: Double = 0.5
    @Published private(set) var isMuted = false
    @Published private(set) var outputName = "扬声器"

    var percent: Int { Int((isMuted ? 0 : level * 100).rounded()) }

    private var deviceID: AudioDeviceID = 0
    private var listeners: [Listener] = []

    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    func start() {
        refreshDevice()
    }

    func stop() {
        removeListeners()
    }

    func setLevel(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        guard let device = resolvedDevice() else { return }
        level = clamped
        if clamped > 0.001, isMuted {
            writeMute(false, device: device)
            isMuted = false
        }
        _ = writeVolume(clamped, device: device)
    }

    func adjust(by delta: Double) {
        setLevel(level + delta)
    }

    func toggleMute() {
        guard let device = resolvedDevice() else { return }
        let next = !isMuted
        writeMute(next, device: device)
        isMuted = next
    }

    func openSoundSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.sound"
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    func refresh() {
        guard let device = resolvedDevice() else { return }
        let nextLevel = Double(readVolume(device: device))
        let nextMuted = readMute(device: device)
        let nextName = readName(device: device) ?? "扬声器"
        if abs(nextLevel - level) > 0.004 { level = nextLevel }
        if nextMuted != isMuted { isMuted = nextMuted }
        if nextName != outputName { outputName = nextName }
    }

    private func refreshDevice() {
        removeListeners()
        deviceID = readDefaultOutputDevice()
        listenForDefaultDeviceChanges()
        listenOnDevice()
        refresh()
    }

    private func resolvedDevice() -> AudioDeviceID? {
        let current = readDefaultOutputDevice()
        if current != 0, current != deviceID {
            deviceID = current
            removeListeners()
            listenForDefaultDeviceChanges()
            listenOnDevice()
        }
        return deviceID == 0 ? nil : deviceID
    }

    private func readDefaultOutputDevice() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        return status == noErr ? device : 0
    }

    private func listenForDefaultDeviceChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        addListener(AudioObjectID(kAudioObjectSystemObject), &address) { [weak self] in
            self?.refreshDevice()
        }
    }

    private func listenOnDevice() {
        guard deviceID != 0 else { return }
        for var address in Self.volumeAddresses + Self.muteAddresses {
            addListener(deviceID, &address) { [weak self] in self?.refresh() }
        }
    }

    private func addListener(
        _ object: AudioObjectID,
        _ address: inout AudioObjectPropertyAddress,
        handler: @escaping () -> Void
    ) {
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in
                handler()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
        if status == noErr {
            listeners.append(Listener(object: object, address: address, block: block))
        }
    }

    private func removeListeners() {
        for index in listeners.indices {
            AudioObjectRemovePropertyListenerBlock(
                listeners[index].object,
                &listeners[index].address,
                .main,
                listeners[index].block
            )
        }
        listeners.removeAll()
    }

    private func readVolume(device: AudioDeviceID) -> Float {
        for var address in Self.volumeAddresses {
            if let value = getFloat(device, &address) {
                return min(max(value, 0), 1)
            }
        }
        return 0
    }

    @discardableResult
    private func writeVolume(_ value: Double, device: AudioDeviceID) -> Bool {
        let scalar = Float(value)
        var wrote = false
        for var address in Self.volumeAddresses where isSettable(device, &address) {
            if setFloat(device, &address, scalar) {
                wrote = true
                // Virtual / main-element volume is the system control; stop after the first hit.
                if address.mElement == kAudioObjectPropertyElementMain {
                    return true
                }
            }
        }
        return wrote
    }

    private func readMute(device: AudioDeviceID) -> Bool {
        for var address in Self.muteAddresses {
            if let value = getUInt32(device, &address) {
                return value != 0
            }
        }
        return false
    }

    private func writeMute(_ muted: Bool, device: AudioDeviceID) {
        let value: UInt32 = muted ? 1 : 0
        for var address in Self.muteAddresses where isSettable(device, &address) {
            if setUInt32(device, &address, value) { return }
        }
    }

    private func readName(device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private func isSettable(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address) else { return false }
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private func getFloat(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Float? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func setFloat(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress, _ value: Float) -> Bool {
        var mutable = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &mutable) == noErr
    }

    private func getUInt32(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> UInt32? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func setUInt32(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
        var mutable = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &mutable) == noErr
    }

    /// Built-in Mac speakers expose volume on output/main. Virtual volume is
    /// the software control used by Bluetooth / HDMI devices. Stereo channels
    /// are a last resort.
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D7663) // 'vmvc'
    private static let virtualMainMute = AudioObjectPropertySelector(0x766D6D63) // 'vmmc'

    private static let volumeAddresses: [AudioObjectPropertyAddress] = [
        property(virtualMainVolume, scope: kAudioDevicePropertyScopeOutput, element: kAudioObjectPropertyElementMain),
        property(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: kAudioObjectPropertyElementMain),
        property(virtualMainVolume, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain),
        property(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: 1),
        property(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: 2)
    ]

    private static let muteAddresses: [AudioObjectPropertyAddress] = [
        property(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: kAudioObjectPropertyElementMain),
        property(virtualMainMute, scope: kAudioDevicePropertyScopeOutput, element: kAudioObjectPropertyElementMain),
        property(virtualMainMute, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain),
        property(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: 1),
        property(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: 2)
    ]

    private static func property(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}
