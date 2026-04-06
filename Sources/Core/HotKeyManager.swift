import Carbon
import Foundation

@MainActor
final class HotKeyManager {
    private static let signature: OSType = 0x434C5744
    private static let allowKeyID: UInt32 = 1
    private static let denyKeyID: UInt32 = 2
    private static let toggleVisibilityKeyID: UInt32 = 3

    private var allowRef: EventHotKeyRef?
    private var denyRef: EventHotKeyRef?
    private var toggleVisibilityRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var onAllow: @MainActor () -> Void = {}
    var onDeny: @MainActor () -> Void = {}
    var onToggleVisibility: @MainActor () -> Void = {}

    func register() {
        installHandlerIfNeeded()

        if allowRef == nil {
            let allowID = EventHotKeyID(signature: Self.signature, id: Self.allowKeyID)
            // Ctrl+Shift+Y 直接命中最新权限气泡的 Allow。
            let status = RegisterEventHotKey(
                16,
                UInt32(controlKey | shiftKey),
                allowID,
                GetApplicationEventTarget(),
                0,
                &allowRef
            )
            if status != noErr {
                print("hotkey registration failed for Allow: \(status)")
            }
        }

        if denyRef == nil {
            let denyID = EventHotKeyID(signature: Self.signature, id: Self.denyKeyID)
            // Ctrl+Shift+N 对应 Deny，和原计划保持一致。
            let status = RegisterEventHotKey(
                45,
                UInt32(controlKey | shiftKey),
                denyID,
                GetApplicationEventTarget(),
                0,
                &denyRef
            )
            if status != noErr {
                print("hotkey registration failed for Deny: \(status)")
            }
        }
    }

    func registerVisibilityToggle() {
        installHandlerIfNeeded()

        if toggleVisibilityRef == nil {
            let toggleID = EventHotKeyID(signature: Self.signature, id: Self.toggleVisibilityKeyID)
            // Cmd+Shift+C 始终保留给显示/隐藏桌宠，不受气泡显示状态影响。
            let status = RegisterEventHotKey(
                UInt32(kVK_ANSI_C),
                UInt32(cmdKey | shiftKey),
                toggleID,
                GetApplicationEventTarget(),
                0,
                &toggleVisibilityRef
            )
            if status != noErr {
                print("hotkey registration failed for Toggle Visibility: \(status)")
            }
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

    private func unregisterVisibilityToggle() {
        if let ref = toggleVisibilityRef {
            UnregisterEventHotKey(ref)
            toggleVisibilityRef = nil
        }
    }

    func teardown() {
        unregister()
        unregisterVisibilityToggle()

        if let ref = handlerRef {
            RemoveEventHandler(ref)
            // Balance the passRetained from installHandlerIfNeeded.
            Unmanaged.passUnretained(self).release()
            handlerRef = nil
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
                return OSStatus(eventNotHandledErr)
            }

            let hotKeyManager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                hotKeyManager.handle(event: event)
            }
            return noErr
        }

        let userData = Unmanaged.passRetained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            userData,
            &handlerRef
        )
        if status != noErr {
            Unmanaged<HotKeyManager>.fromOpaque(userData).release()
            print("hotkey handler installation failed: \(status)")
        }
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
        case Self.toggleVisibilityKeyID:
            onToggleVisibility()
        default:
            break
        }
    }
}
