import AppKit
import Foundation

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
        if screen.frame.intersects(savedFrame) {
            restoredX = savedOrigin.x
        } else {
            let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
            restoredX = min(max(savedOrigin.x, visibleFrame.minX), maxX)
        }

        return NSPoint(x: restoredX, y: clampedY)
    }

    private func hasValue(for key: PrefKey) -> Bool {
        defaults.object(forKey: key.rawValue) != nil
    }

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
