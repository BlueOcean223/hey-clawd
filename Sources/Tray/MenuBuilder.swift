import AppKit
import Foundation

enum AppLanguage: String {
    case en
    case zh
}

struct AppMenuState {
    var language: AppLanguage
    var sizePreset: PetWindow.SizePreset
    var isMiniModeEnabled: Bool
    var isDoNotDisturbEnabled: Bool
    var isBubbleFollowEnabled: Bool
    var isHideBubblesEnabled: Bool
    var isSoundEffectsEnabled: Bool
    var isPetVisible: Bool
    var sessions: [SessionMenuSnapshot]
}

@MainActor
enum MenuBuilder {
    private static let strings: [AppLanguage: [String: String]] = [
        .en: [
            "size": "Size",
            "small": "Small (S)",
            "medium": "Medium (M)",
            "large": "Large (L)",
            "miniMode": "Mini Mode",
            "sessions": "Sessions",
            "noSessions": "No active sessions",
            "sleep": "Sleep (Do Not Disturb)",
            "wake": "Wake Clawd",
            "soundEffects": "Sound Effects",
            "bubbleFollow": "Bubble Follow Pet",
            "hideBubbles": "Hide Bubbles",
            "language": "Language",
            "english": "English",
            "chinese": "中文",
            "checkForUpdates": "Check for Updates",
            "showPet": "Show Clawd",
            "hidePet": "Hide Clawd",
            "quit": "Quit",
        ],
        .zh: [
            "size": "大小",
            "small": "小 (S)",
            "medium": "中 (M)",
            "large": "大 (L)",
            "miniMode": "极简模式",
            "sessions": "会话",
            "noSessions": "没有活跃会话",
            "sleep": "休眠（免打扰）",
            "wake": "唤醒 Clawd",
            "soundEffects": "音效",
            "bubbleFollow": "气泡跟随桌宠",
            "hideBubbles": "隐藏气泡",
            "language": "语言",
            "english": "English",
            "chinese": "中文",
            "checkForUpdates": "检查更新",
            "showPet": "显示 Clawd",
            "hidePet": "隐藏 Clawd",
            "quit": "退出",
        ],
    ]

    private static let enRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let zhRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.unitsStyle = .short
        return formatter
    }()

    static func build(state: AppMenuState, target: StatusBarController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(sizeMenuItem(state: state, target: target))
        menu.addItem(.separator())
        menu.addItem(toggleItem(
            title: text("miniMode", lang: state.language),
            selector: #selector(StatusBarController.toggleMiniMode(_:)),
            isOn: state.isMiniModeEnabled,
            target: target,
            isEnabled: false
        ))
        menu.addItem(sessionsMenuItem(state: state, target: target))
        menu.addItem(actionItem(
            title: text(state.isDoNotDisturbEnabled ? "wake" : "sleep", lang: state.language),
            selector: #selector(StatusBarController.toggleDoNotDisturb(_:)),
            target: target
        ))
        menu.addItem(.separator())
        menu.addItem(toggleItem(
            title: text("bubbleFollow", lang: state.language),
            selector: #selector(StatusBarController.toggleBubbleFollow(_:)),
            isOn: state.isBubbleFollowEnabled,
            target: target,
            isEnabled: false
        ))
        menu.addItem(toggleItem(
            title: text("hideBubbles", lang: state.language),
            selector: #selector(StatusBarController.toggleHideBubbles(_:)),
            isOn: state.isHideBubblesEnabled,
            target: target,
            isEnabled: false
        ))
        menu.addItem(toggleItem(
            title: text("soundEffects", lang: state.language),
            selector: #selector(StatusBarController.toggleSoundEffects(_:)),
            isOn: state.isSoundEffectsEnabled,
            target: target,
            isEnabled: false
        ))
        menu.addItem(.separator())
        menu.addItem(languageMenuItem(state: state, target: target))
        menu.addItem(actionItem(
            title: text("checkForUpdates", lang: state.language),
            selector: #selector(StatusBarController.checkForUpdates(_:)),
            target: target
        ))
        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: text(state.isPetVisible ? "hidePet" : "showPet", lang: state.language),
            selector: #selector(StatusBarController.togglePetVisibility(_:)),
            target: target
        ))
        menu.addItem(actionItem(
            title: text("quit", lang: state.language),
            selector: #selector(StatusBarController.quit(_:)),
            target: target
        ))

        return menu
    }

    private static func sizeMenuItem(state: AppMenuState, target: StatusBarController) -> NSMenuItem {
        let item = NSMenuItem(title: text("size", lang: state.language), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(sizeOption(
            title: text("small", lang: state.language),
            preset: .small,
            selected: state.sizePreset == .small,
            target: target
        ))
        submenu.addItem(sizeOption(
            title: text("medium", lang: state.language),
            preset: .medium,
            selected: state.sizePreset == .medium,
            target: target
        ))
        submenu.addItem(sizeOption(
            title: text("large", lang: state.language),
            preset: .large,
            selected: state.sizePreset == .large,
            target: target
        ))
        item.submenu = submenu
        return item
    }

    private static func sessionsMenuItem(state: AppMenuState, target: StatusBarController) -> NSMenuItem {
        let item = NSMenuItem(title: text("sessions", lang: state.language), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if state.sessions.isEmpty {
            let empty = NSMenuItem(title: text("noSessions", lang: state.language), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for session in state.sessions {
                let sessionItem = actionItem(
                    title: sessionTitle(session, lang: state.language),
                    selector: #selector(StatusBarController.focusSession(_:)),
                    target: target
                )
                sessionItem.representedObject = session.sourcePid
                sessionItem.isEnabled = session.sourcePid != nil
                submenu.addItem(sessionItem)
            }
        }

        item.submenu = submenu
        return item
    }

    private static func languageMenuItem(state: AppMenuState, target: StatusBarController) -> NSMenuItem {
        let item = NSMenuItem(title: text("language", lang: state.language), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let english = actionItem(
            title: text("english", lang: state.language),
            selector: #selector(StatusBarController.selectLanguage(_:)),
            target: target
        )
        english.representedObject = AppLanguage.en
        english.state = state.language == .en ? .on : .off
        submenu.addItem(english)

        let chinese = actionItem(
            title: text("chinese", lang: state.language),
            selector: #selector(StatusBarController.selectLanguage(_:)),
            target: target
        )
        chinese.representedObject = AppLanguage.zh
        chinese.state = state.language == .zh ? .on : .off
        submenu.addItem(chinese)

        item.submenu = submenu
        return item
    }

    private static func sizeOption(
        title: String,
        preset: PetWindow.SizePreset,
        selected: Bool,
        target: StatusBarController
    ) -> NSMenuItem {
        let item = actionItem(
            title: title,
            selector: #selector(StatusBarController.selectSizePreset(_:)),
            target: target
        )
        item.representedObject = preset
        item.state = selected ? .on : .off
        return item
    }

    private static func toggleItem(
        title: String,
        selector: Selector,
        isOn: Bool,
        target: StatusBarController,
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = actionItem(title: title, selector: selector, target: target)
        item.state = isOn ? .on : .off
        item.isEnabled = isEnabled
        return item
    }

    private static func actionItem(title: String, selector: Selector, target: StatusBarController) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        return item
    }

    private static func text(_ key: String, lang: AppLanguage) -> String {
        strings[lang]?[key] ?? key
    }

    private static func sessionTitle(_ session: SessionMenuSnapshot, lang: AppLanguage) -> String {
        let name = session.cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
            ?? session.agentId
            ?? session.id
        let formatter = lang == .zh ? zhRelativeFormatter : enRelativeFormatter
        let age = formatter.localizedString(for: session.updatedAt, relativeTo: Date())
        return "\(emoji(for: session.state)) \(name) \(stateLabel(for: session.state, lang: lang)) \(age)"
    }

    private static func emoji(for state: PetState) -> String {
        switch state {
        case .working, .juggling, .carrying, .sweeping:
            return "🔨"
        case .thinking:
            return "💭"
        case .attention, .notification:
            return "🔔"
        case .error:
            return "⚠️"
        case .sleeping, .yawning, .dozing, .collapsing, .waking:
            return "😴"
        default:
            return "•"
        }
    }

    private static func stateLabel(for state: PetState, lang: AppLanguage) -> String {
        switch (lang, state) {
        case (.zh, .working): return "工作中"
        case (.zh, .thinking): return "思考中"
        case (.zh, .juggling): return "忙碌中"
        case (.zh, .carrying): return "搬运中"
        case (.zh, .attention): return "提醒"
        case (.zh, .notification): return "通知"
        case (.zh, .error): return "出错"
        case (.zh, .sleeping), (.zh, .yawning), (.zh, .dozing), (.zh, .collapsing), (.zh, .waking): return "休眠"
        case (.zh, _): return "空闲"
        case (.en, .working): return "Working"
        case (.en, .thinking): return "Thinking"
        case (.en, .juggling): return "Juggling"
        case (.en, .carrying): return "Carrying"
        case (.en, .attention): return "Attention"
        case (.en, .notification): return "Notification"
        case (.en, .error): return "Error"
        case (.en, .sleeping), (.en, .yawning), (.en, .dozing), (.en, .collapsing), (.en, .waking): return "Sleeping"
        case (.en, _): return "Idle"
        }
    }
}
