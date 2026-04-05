import Carbon
import Foundation

@MainActor
final class HotKeyManager {
    private static let signature: OSType = 0x434C5744
    private static let allowKeyID: UInt32 = 1
    private static let denyKeyID: UInt32 = 2

    private var allowRef: EventHotKeyRef?
    private var denyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var onAllow: @MainActor () -> Void = {}
    var onDeny: @MainActor () -> Void = {}

    func register() {
        installHandlerIfNeeded()

        if allowRef == nil {
            let allowID = EventHotKeyID(signature: Self.signature, id: Self.allowKeyID)
            // Ctrl+Shift+Y 直接命中最新权限气泡的 Allow。
            RegisterEventHotKey(16, UInt32(controlKey | shiftKey), allowID, GetApplicationEventTarget(), 0, &allowRef)
        }

        if denyRef == nil {
            let denyID = EventHotKeyID(signature: Self.signature, id: Self.denyKeyID)
            // Ctrl+Shift+N 对应 Deny，和原计划保持一致。
            RegisterEventHotKey(45, UInt32(controlKey | shiftKey), denyID, GetApplicationEventTarget(), 0, &denyRef)
        }
    }

    func unregister() {
        if let ref = allowRef {
            UnregisterEventHotKey(ref)
            allowRef = nil
        }

        if let ref = denyRef {
            UnregisterEventHotKey(ref)
            denyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard
                let event,
                let userData
            else {
                return noErr
            }

            let hotKeyManager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            hotKeyManager.handle(event: event)
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func handle(event: EventRef) {
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

        guard status == noErr, hotKeyID.signature == Self.signature else {
            return
        }

        switch hotKeyID.id {
        case Self.allowKeyID:
            onAllow()
        case Self.denyKeyID:
            onDeny()
        default:
            break
        }
    }
}
