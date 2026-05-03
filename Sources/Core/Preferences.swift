import AppKit
import Foundation

/// 所有持久化偏好的 key 常量；改动时记得在 `defaults.register` 与 `restoredWindowOrigin` 同步。
enum PrefKey: String {
    case windowX
    case windowY
    case windowSize
    case miniMode
    case miniEdge
    case preMiniX
    case preMiniY
    case lang
    case soundMuted
    case doNotDisturb
    case bubbleFollowPet
    case hideBubbles
    case showSessionId
    case autoFocusSession
}

/// 围绕 `UserDefaults` 的强类型偏好封装。
///
/// 单例 + `@MainActor` 是因为 UI 路径会同步读，避免 actor 跨域调用；偏好值都是
/// 小数据，无需关心线程安全。每个属性都 `register` 了默认值，
/// 这样 `bool(forKey:)` 等同步 API 永远拿到合理值。
@MainActor
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // 先注册默认值，后面的读取逻辑就可以只关心类型转换。
        defaults.register(defaults: [
            PrefKey.windowSize.rawValue: 100,
            PrefKey.miniMode.rawValue: false,
            PrefKey.miniEdge.rawValue: "right",
            PrefKey.lang.rawValue: AppLanguage.zh.rawValue,
            PrefKey.soundMuted.rawValue: false,
            PrefKey.doNotDisturb.rawValue: false,
            PrefKey.bubbleFollowPet.rawValue: true,
            PrefKey.hideBubbles.rawValue: false,
            PrefKey.showSessionId.rawValue: false,
            PrefKey.autoFocusSession.rawValue: false,
        ])
    }

    /// 上次主窗口位置；首次启动或用户主动重置时返回 nil 让 PetWindow 用默认坐标。
    var windowOrigin: NSPoint? {
        get {
            guard hasValue(for: .windowX), hasValue(for: .windowY) else {
                return nil
            }

            return NSPoint(
                x: defaults.double(forKey: PrefKey.windowX.rawValue),
                y: defaults.double(forKey: PrefKey.windowY.rawValue)
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: PrefKey.windowX.rawValue)
                defaults.removeObject(forKey: PrefKey.windowY.rawValue)
                return
            }

            defaults.set(Double(newValue.x), forKey: PrefKey.windowX.rawValue)
            defaults.set(Double(newValue.y), forKey: PrefKey.windowY.rawValue)
        }
    }

    /// 老版本写入过 "S/M/L" 字符串预设；这里做一次性转换映射到等效百分比，
    /// 同时夹紧到 25–400% 区间防止恶意/损坏的 UserDefaults 把窗口拉到不可见尺寸。
    var windowSizePercent: Int {
        get {
            let raw = defaults.object(forKey: PrefKey.windowSize.rawValue)
            let value: Int
            if let intValue = raw as? Int {
                value = intValue
            } else if let stringValue = raw as? String {
                switch stringValue {
                case "M": value = 140
                case "L": value = 180
                default: value = 100
                }
            } else {
                value = 100
            }
            return min(max(value, 25), 400)
        }
        set {
            defaults.set(newValue, forKey: PrefKey.windowSize.rawValue)
        }
    }

    var miniModeEnabled: Bool {
        get { defaults.bool(forKey: PrefKey.miniMode.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.miniMode.rawValue) }
    }

    var miniEdge: String {
        get { defaults.string(forKey: PrefKey.miniEdge.rawValue) ?? "right" }
        set { defaults.set(newValue, forKey: PrefKey.miniEdge.rawValue) }
    }

    /// 进入 mini 模式之前的位置；退出 mini 时用它把桌宠还原到原处。
    var preMiniOrigin: NSPoint? {
        get {
            guard hasValue(for: .preMiniX), hasValue(for: .preMiniY) else {
                return nil
            }

            return NSPoint(
                x: defaults.double(forKey: PrefKey.preMiniX.rawValue),
                y: defaults.double(forKey: PrefKey.preMiniY.rawValue)
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: PrefKey.preMiniX.rawValue)
                defaults.removeObject(forKey: PrefKey.preMiniY.rawValue)
                return
            }

            defaults.set(Double(newValue.x), forKey: PrefKey.preMiniX.rawValue)
            defaults.set(Double(newValue.y), forKey: PrefKey.preMiniY.rawValue)
        }
    }

    var language: AppLanguage {
        get {
            AppLanguage(rawValue: defaults.string(forKey: PrefKey.lang.rawValue) ?? "") ?? .zh
        }
        set {
            defaults.set(newValue.rawValue, forKey: PrefKey.lang.rawValue)
        }
    }

    var soundMuted: Bool {
        get { defaults.bool(forKey: PrefKey.soundMuted.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.soundMuted.rawValue) }
    }

    var doNotDisturbEnabled: Bool {
        get { defaults.bool(forKey: PrefKey.doNotDisturb.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.doNotDisturb.rawValue) }
    }

    var bubbleFollowPet: Bool {
        get { defaults.bool(forKey: PrefKey.bubbleFollowPet.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.bubbleFollowPet.rawValue) }
    }

    var hideBubbles: Bool {
        get { defaults.bool(forKey: PrefKey.hideBubbles.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.hideBubbles.rawValue) }
    }

    var showSessionId: Bool {
        get { defaults.bool(forKey: PrefKey.showSessionId.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.showSessionId.rawValue) }
    }

    var autoFocusSession: Bool {
        get { defaults.bool(forKey: PrefKey.autoFocusSession.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.autoFocusSession.rawValue) }
    }

    /// 常规恢复时只强制压回 Y 轴，避免顶部菜单栏或 Dock 挤掉桌宠。
    /// 如果原来的屏幕已经不存在，再顺手把 X 轴也压回当前可见屏幕，防止窗口完全丢失。
    func restoredWindowOrigin(for size: NSSize, screens: [NSScreen] = NSScreen.screens) -> NSPoint? {
        guard let savedOrigin = windowOrigin else {
            return nil
        }

        guard let screen = preferredScreen(for: savedOrigin, size: size, screens: screens) else {
            return savedOrigin
        }

        let visibleFrame = screen.visibleFrame
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        let clampedY = min(max(savedOrigin.y, visibleFrame.minY), maxY)

        let savedFrame = NSRect(origin: savedOrigin, size: size)
        let restoredX: CGFloat
        // 已保存位置仍然落在某个屏幕内：保留 X，避免连接外接显示器后桌宠被挪位置。
        if screen.frame.intersects(savedFrame) {
            restoredX = savedOrigin.x
        } else {
            let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
            restoredX = min(max(savedOrigin.x, visibleFrame.minX), maxX)
        }

        return NSPoint(x: restoredX, y: clampedY)
    }

    /// `defaults.bool/double` 区分不出"未设置"和"显式 false/0"；用 `object(forKey:) == nil` 显式判定。
    private func hasValue(for key: PrefKey) -> Bool {
        defaults.object(forKey: key.rawValue) != nil
    }

    /// 多屏匹配按优先级：完整覆盖 → 仅 X 轴覆盖 → 主屏 → 任意屏。
    /// 兼顾"原屏幕被拔掉"和"屏幕排列方式变化"两种常见外接屏场景。
    private func preferredScreen(for origin: NSPoint, size: NSSize, screens: [NSScreen]) -> NSScreen? {
        let savedFrame = NSRect(origin: origin, size: size)

        if let matchingScreen = screens.first(where: { $0.frame.intersects(savedFrame) }) {
            return matchingScreen
        }

        if let matchingXScreen = screens.first(where: { screen in
            let frame = screen.frame
            return origin.x >= frame.minX && origin.x <= frame.maxX
        }) {
            return matchingXScreen
        }

        return NSScreen.main ?? screens.first
    }
}
