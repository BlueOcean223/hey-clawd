import AppKit
import Foundation

enum AppLanguage: String {
    case en
    case zh
}

struct AppMenuState {
    var language: AppLanguage
    var sizePercent: Int
    var isMiniModeEnabled: Bool
    var isMiniTransitioning: Bool
    var isDoNotDisturbEnabled: Bool
    var isBubbleFollowEnabled: Bool
    var isHideBubblesEnabled: Bool
    var isSoundEffectsEnabled: Bool
    var isAutoFocusEnabled: Bool
    var isPetVisible: Bool
    var sessions: [SessionMenuSnapshot]
}

@MainActor
enum MenuBuilder {
    private static let strings: [AppLanguage: [String: String]] = [
        .en: [
            "size": "Size",
            "custom": "Custom...",
            "miniMode": "Mini Mode",
            "exitMiniMode": "Exit Mini Mode",
            "sessions": "Sessions",
            "noSessions": "No active sessions",
            "sleep": "Sleep (Do Not Disturb)",
            "wake": "Wake Clawd",
            "soundEffects": "Sound Effects",
            "autoFocus": "Auto Focus Session",
            "bubbleFollow": "Bubble Follow Pet",
            "hideBubbles": "Hide Bubbles",
            "language": "Language",
            "english": "English",
            "chinese": "中文",
            "checkForUpdates": "Check for Updates",
            "hooks": "Hooks",
            "register": "Register",
            "registerAll": "Register All",
            "unregister": "Clean",
            "unregisterAll": "Clean All",
            "showPet": "Show Clawd",
            "hidePet": "Hide Clawd",
            "quit": "Quit",
        ],
        .zh: [
            "size": "大小",
            "custom": "自定义...",
            "miniMode": "极简模式",
            "exitMiniMode": "退出极简模式",
            "sessions": "会话",
            "noSessions": "没有活跃会话",
            "sleep": "休眠（免打扰）",
            "wake": "唤醒 Clawd",
            "soundEffects": "音效",
            "autoFocus": "自动聚焦会话",
            "bubbleFollow": "气泡跟随桌宠",
            "hideBubbles": "隐藏气泡",
            "language": "语言",
            "english": "English",
            "chinese": "中文",
            "checkForUpdates": "检查更新",
            "hooks": "Hooks",
            "register": "注册",
            "registerAll": "全部注册",
            "unregister": "清理",
            "unregisterAll": "全部清理",
            "showPet": "显示 Clawd",
            "hidePet": "隐藏 Clawd",
            "quit": "退出",
        ],
    ]

    private static let sizePresets = [50, 75, 100, 125, 150, 200, 250]
    private static let defaultAgentIconName = "claude-code"
    private static let agentIconNames: Set<String> = [
        "claude-code",
        "codex",
        "copilot-cli",
        "cursor-agent",
        "gemini-cli",
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
            title: text(state.isMiniModeEnabled ? "exitMiniMode" : "miniMode", lang: state.language),
            selector: #selector(StatusBarController.toggleMiniMode(_:)),
            isOn: state.isMiniModeEnabled,
            target: target,
            isEnabled: !state.isMiniTransitioning
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
            target: target
        ))
        menu.addItem(toggleItem(
            title: text("hideBubbles", lang: state.language),
            selector: #selector(StatusBarController.toggleHideBubbles(_:)),
            isOn: state.isHideBubblesEnabled,
            target: target
        ))
        menu.addItem(toggleItem(
            title: text("soundEffects", lang: state.language),
            selector: #selector(StatusBarController.toggleSoundEffects(_:)),
            isOn: state.isSoundEffectsEnabled,
            target: target
        ))
        menu.addItem(toggleItem(
            title: text("autoFocus", lang: state.language),
            selector: #selector(StatusBarController.toggleAutoFocusSession(_:)),
            isOn: state.isAutoFocusEnabled,
            target: target
        ))
        menu.addItem(.separator())
        menu.addItem(languageMenuItem(state: state, target: target))
        if target.shouldShowCheckForUpdatesMenu() {
            menu.addItem(checkForUpdatesMenuItem(state: state, target: target))
        }
        menu.addItem(hooksMenuItem(state: state, target: target))
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

        for percent in sizePresets {
            let title = "\(percent)%"
            let menuItem = actionItem(
                title: title,
                selector: #selector(StatusBarController.selectSizePercent(_:)),
                target: target
            )
            menuItem.representedObject = percent
            menuItem.state = state.sizePercent == percent ? .on : .off
            submenu.addItem(menuItem)
        }

        submenu.addItem(.separator())

        let customItem = actionItem(
            title: text("custom", lang: state.language),
            selector: #selector(StatusBarController.selectCustomSize(_:)),
            target: target
        )
        if !sizePresets.contains(state.sizePercent) {
            customItem.title = "\(text("custom", lang: state.language)) (\(state.sizePercent)%)"
            customItem.state = .on
        }
        submenu.addItem(customItem)

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
                sessionItem.representedObject = session
                sessionItem.isEnabled = session.sourcePid != nil || session.editor != nil
                sessionItem.image = agentIcon(for: session.agentId)
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

    private static func hooksMenuItem(state: AppMenuState, target: StatusBarController) -> NSMenuItem {
        let item = NSMenuItem(title: text("hooks", lang: state.language), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let registerItem = NSMenuItem(title: text("register", lang: state.language), action: nil, keyEquivalent: "")
        let registerSubmenu = NSMenu()
        registerSubmenu.autoenablesItems = false

        for hookTarget in HookInstaller.HookTarget.allCases {
            let entry = actionItem(
                title: hookTarget.displayName,
                selector: #selector(StatusBarController.registerHooks(_:)),
                target: target
            )
            entry.representedObject = hookTarget
            entry.image = hookTargetIconName(hookTarget).flatMap(loadAgentIcon(named:))
            registerSubmenu.addItem(entry)
        }

        registerSubmenu.addItem(.separator())
        registerSubmenu.addItem(actionItem(
            title: text("registerAll", lang: state.language),
            selector: #selector(StatusBarController.registerHooks(_:)),
            target: target
        ))

        registerItem.submenu = registerSubmenu
        submenu.addItem(registerItem)

        let unregisterItem = NSMenuItem(title: text("unregister", lang: state.language), action: nil, keyEquivalent: "")
        let unregisterSubmenu = NSMenu()
        unregisterSubmenu.autoenablesItems = false

        for hookTarget in HookInstaller.HookTarget.allCases {
            let entry = actionItem(
                title: hookTarget.displayName,
                selector: #selector(StatusBarController.unregisterHooks(_:)),
                target: target
            )
            entry.representedObject = hookTarget
            entry.image = hookTargetIconName(hookTarget).flatMap(loadAgentIcon(named:))
            unregisterSubmenu.addItem(entry)
        }

        unregisterSubmenu.addItem(.separator())
        unregisterSubmenu.addItem(actionItem(
            title: text("unregisterAll", lang: state.language),
            selector: #selector(StatusBarController.unregisterHooks(_:)),
            target: target
        ))

        unregisterItem.submenu = unregisterSubmenu
        submenu.addItem(unregisterItem)

        item.submenu = submenu
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

    private static func checkForUpdatesMenuItem(state: AppMenuState, target: StatusBarController) -> NSMenuItem {
        // 直接把菜单项交给 Sparkle 控制器，保持和官方接法一致。
        let item = actionItem(
            title: text("checkForUpdates", lang: state.language),
            selector: target.checkForUpdatesMenuAction ?? #selector(StatusBarController.checkForUpdates(_:)),
            target: target.checkForUpdatesMenuTarget ?? target
        )
        item.isEnabled = target.canCheckForUpdatesMenu()
        return item
    }

    private static func actionItem(title: String, selector: Selector?, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        return item
    }

    private static func text(_ key: String, lang: AppLanguage) -> String {
        strings[lang]?[key] ?? key
    }

    private static func hookTargetIconName(_ target: HookInstaller.HookTarget) -> String? {
        switch target {
        case .claudeCode:
            return "claude-code"
        case .gemini:
            return "gemini-cli"
        case .cursor:
            return "cursor-agent"
        case .codeBuddy:
            return nil
        }
    }

    private static func agentIcon(for agentId: String?) -> NSImage? {
        let iconName = normalizedAgentIconName(for: agentId)
        return loadAgentIcon(named: iconName)
            ?? (iconName == defaultAgentIconName ? nil : loadAgentIcon(named: defaultAgentIconName))
    }

    private static func normalizedAgentIconName(for agentId: String?) -> String {
        let key = agentId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let key, agentIconNames.contains(key) else {
            return defaultAgentIconName
        }

        return key
    }

    private static func loadAgentIcon(named iconName: String) -> NSImage? {
        guard
            let iconURL = agentIconURL(named: iconName),
            let image = NSImage(contentsOf: iconURL)
        else {
            return nil
        }

        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = false
        return image
    }

    private static func agentIconURL(named iconName: String) -> URL? {
        let relativePath = "icons/agents/\(iconName).png"
        let fileManager = FileManager.default

        for resourceURL in bundledResourceCandidates() {
            let iconURL = resourceURL.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: iconURL.path) {
                return iconURL
            }
        }

        return nil
    }

    private static func bundledResourceCandidates() -> [URL] {
        var candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Resources", isDirectory: true),
            Bundle.main.resourceURL,
        ]

#if SWIFT_PACKAGE
        candidates.insert(Bundle.module.resourceURL?.appendingPathComponent("Resources", isDirectory: true), at: 0)
        candidates.insert(Bundle.module.resourceURL, at: 1)
#endif

        return candidates.compactMap { $0 }
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
