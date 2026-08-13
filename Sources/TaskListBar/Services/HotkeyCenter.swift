import AppKit
import Carbon
import Foundation

final class HotkeyCenter {
    enum Action: UInt32 {
        case startMenu = 1
        case calendar = 2
    }

    var onAction: ((Action) -> Void)?

    private var refs: [Action: EventHotKeyRef] = [:]
    private var chords: [Action: HotkeyChord] = [:]
    private var handlerRef: EventHandlerRef?
    private var suspended = false

    private static let signature: OSType = 0x544C_4248

    init() {
        installHandler()
    }

    deinit {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func setChord(_ chord: HotkeyChord?, for action: Action) {
        chords[action] = chord
        reregister(action)
    }

    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        for action in [Action.startMenu, .calendar] {
            reregister(action)
        }
    }

    private func reregister(_ action: Action) {
        if let existing = refs.removeValue(forKey: action) {
            UnregisterEventHotKey(existing)
        }
        guard !suspended, let chord = chords[action], chord.isValid else { return }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            UInt32(chord.keyCode),
            chord.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            refs[action] = ref
        } else {
            AppLog.warn("注册失败 \(String(describing: action)) status=\(status)", category: "hotkey")
        }
    }

    private func unregisterAll() {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let actionID = hotKeyID.id
            DispatchQueue.main.async {
                let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                guard let action = Action(rawValue: actionID) else { return }
                center.onAction?(action)
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            userData,
            &handlerRef
        )
    }
}
