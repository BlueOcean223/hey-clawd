import Carbon
import Foundation

/// 全局热键管理：注册 Allow / Deny / Toggle Visibility 三组系统级快捷键。
///
/// 走 Carbon 的 `RegisterEventHotKey` 是因为 AppKit 的 NSEvent 监听拿不到
/// app 未激活时的按键。该 API 为 C 接口，因此本类需要小心处理 retain/release：
/// `installHandlerIfNeeded` 用 `passRetained` 把 self 暴露给 C 回调，
/// `teardown` 必须 `release` 配平，否则会泄漏对象 + handler。
@MainActor
final class HotKeyManager {
    /// 4 字节 OSType 签名 'CLWD'，用于把本应用的 hot key 与系统其它 app 区分开。
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

    /// 仅在有权限气泡时注册 Allow/Deny；避免无气泡时 Ctrl+Shift+Y 等组合误抢系统快捷键。
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

    /// 显示/隐藏桌宠的快捷键独立注册：与气泡生命周期解耦，App 启动后即常驻。
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

    /// 仅注销 Allow/Deny；visibility toggle 由 `unregisterVisibilityToggle` 单独管理。
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

    /// 应用退出前清理所有 Carbon 资源；漏掉这里会留下 handler 与 retain 泄漏。
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

    /// 同一个事件回调只装一次；多次 register 会被这里短路，避免重复回调和重复 retain。
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

            // 只 takeUnretainedValue：retain 计数始终由 teardown 统一释放。
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
            // 安装失败要立刻 release，否则 retain 计数无法在 teardown 中配平。
            Unmanaged<HotKeyManager>.fromOpaque(userData).release()
            print("hotkey handler installation failed: \(status)")
        }
    }

    /// 解析事件参数中的 hot key id，再分发到对应 closure。
    /// signature 不一致时直接忽略——属于其他 app 的 hot key 事件。
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
