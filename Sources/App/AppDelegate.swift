import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem!
    private(set) var petWindow: PetWindow?
    private var statusBarController: StatusBarController?
    private var httpServer: HTTPServer?
    private var httpServerTask: Task<Void, Never>?
    private var stateMachine: StateMachine?
    private var codexMonitor: CodexMonitor?
    private let hotKeyManager = HotKeyManager()
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private let preferences: Preferences
    private var appLanguage: AppLanguage
    private var isMiniModeEnabled: Bool
    private var isMiniTransitioning = false
    private var isBubbleFollowEnabled: Bool
    private var isHideBubblesEnabled: Bool
    private var isSoundEffectsEnabled: Bool
    private var miniModeController: MiniMode?
    private var gitUpdater: GitUpdater?
    private var sparkleUpdater: SparkleUpdater?
    private lazy var bubbleStack = BubbleStack(
        petWindowProvider: { [weak self] in self?.petWindow },
        bubbleFollowProvider: { [weak self] in self?.isBubbleFollowEnabled ?? true }
    )

    override init() {
        let preferences = Preferences.shared
        self.preferences = preferences
        appLanguage = preferences.language
        isMiniModeEnabled = preferences.miniModeEnabled
        isBubbleFollowEnabled = preferences.bubbleFollowPet
        isHideBubblesEnabled = preferences.hideBubbles
        isSoundEffectsEnabled = !preferences.soundMuted
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 配合 Info.plist LSUIElement=true，隐藏 Dock 图标
        NSApp.setActivationPolicy(.accessory)

        // 创建桌面宠物窗口并显示
        petWindow = PetWindow(sizePreset: preferences.windowSizePreset)
        restorePetWindowPositionIfNeeded()
        petWindow?.onDragEnded = { [weak self] origin in
            guard let self else {
                return
            }

            if self.miniModeController?.handleDragEnded() == true {
                return
            }

            self.petWindow?.clampToScreen()
            self.preferences.windowOrigin = self.petWindow?.frame.origin ?? origin
        }
        petWindow?.onDragMove = { [weak self] proposedOrigin in
            guard let self else {
                return proposedOrigin
            }

            return self.miniModeController?.handleDragMove(proposedOrigin: proposedOrigin) ?? proposedOrigin
        }
        petWindow?.onPetClick = { [weak self] in
            self?.focusCurrentSession()
        }
        petWindow?.orderFront(nil)

        hotKeyManager.onAllow = { [weak self] in
            self?.bubbleStack.allowLatestBubble()
        }
        hotKeyManager.onDeny = { [weak self] in
            self?.bubbleStack.denyLatestBubble()
        }
        hotKeyManager.onToggleVisibility = { [weak self] in
            self?.togglePetVisibility()
        }
        // 全局显示/隐藏快捷键始终常驻，不能跟着权限气泡一起注销。
        hotKeyManager.registerVisibilityToggle()
        bubbleStack.onBubblesChanged = { [weak self] in
            self?.updateHotKeyRegistration()
        }
        if let petWindow {
            bubbleStack.observePetWindow(petWindow)
        }

        assembleCoreLoop()
        stateMachine?.setDoNotDisturbEnabled(preferences.doNotDisturbEnabled)
        setupCodexMonitor()
        setupMiniModeController()
        setupUpdater()
        setupStatusBarController()
        installTerminationSignalHandlers()
        updateHotKeyRegistration()
    }

    /// 2.4 的核心装配点：
    /// HTTPServer 接收 hook 请求，StateMachine 决定最终状态和 SVG，
    /// 再由 PetWindow/PetWebView 把结果推到 bridge.js。
    @MainActor
    private func assembleCoreLoop() {
        let stateMachine = StateMachine()
        stateMachine.onStateChange = { [weak self, weak petWindow = self.petWindow] state, svg, sourcePid in
            petWindow?.display(state: state, svgFilename: svg, sourcePid: sourcePid)

            // attention / notification 是“该回到会话看看”的信号，到前台更符合原交互。
            if state == .attention || state == .notification {
                self?.focusCurrentSession()
            }
        }
        stateMachine.onDoNotDisturbChange = { [weak self] enabled in
            guard enabled else {
                return
            }

            self?.bubbleStack.denyAllForDoNotDisturb()
        }
        self.stateMachine = stateMachine

        let server = HTTPServer()
        server.setStateRequestHandler { body in
            Self.handleStateRequest(body, using: stateMachine)
        }
        server.setPermissionRequestHandler { [weak self] request in
            Task { @MainActor [weak self] in
                guard let self else {
                    request.respond(with: .deny)
                    return
                }

                self.presentPermissionBubble(for: request)
            }
        }
        httpServer = server
        httpServerTask = Task { [server] in
            _ = await server.start()
        }
    }

    private func setupUpdater() {
        let gitUpdater = GitUpdater()
        if gitUpdater.isAvailable {
            // 有 .git 就优先走源码更新，避免开发者环境还弹 Sparkle。
            self.gitUpdater = gitUpdater
            sparkleUpdater = nil
            return
        }

        self.gitUpdater = nil

        // Sparkle 依赖 Info.plist 里的 feed / key 配置，打包安装走这条路径。
        sparkleUpdater = SparkleUpdater()
    }

    private func setupCodexMonitor() {
        guard let stateMachine else {
            return
        }

        let monitor = CodexMonitor()
        codexMonitor = monitor
        Task { [stateMachine] in
            await monitor.setOnStateUpdate { [stateMachine] update in
                // emit 已经切回主线程，这里只把会话状态和 cwd 接回主状态机。
                MainActor.assumeIsolated {
                    stateMachine.setState(
                        update.state,
                        sessionId: update.sessionId,
                        event: update.event,
                        sourcePid: nil,
                        cwd: update.cwd,
                        editor: nil,
                        agentId: update.agentId,
                        headless: false
                    )
                }
            }
            await monitor.start()
        }
    }

    private func setupStatusBarController() {
        let controller = StatusBarController { [weak self] in
            self?.currentMenuState ?? AppMenuState(
                language: .zh,
                sizePreset: .small,
                isMiniModeEnabled: false,
                isMiniTransitioning: false,
                isDoNotDisturbEnabled: false,
                isBubbleFollowEnabled: true,
                isHideBubblesEnabled: false,
                isSoundEffectsEnabled: true,
                isPetVisible: true,
                sessions: []
            )
        }
        controller.checkForUpdatesMenuTarget = gitUpdater == nil ? sparkleUpdater?.controller : nil
        controller.checkForUpdatesMenuAction = gitUpdater == nil ? sparkleUpdater?.checkForUpdatesAction : nil
        controller.canCheckForUpdatesMenu = { [weak self] in
            if self?.gitUpdater?.isAvailable == true {
                return true
            }

            return self?.sparkleUpdater?.canCheckForUpdates ?? false
        }

        controller.onTogglePetVisibility = { [weak self] in
            self?.togglePetVisibility()
        }
        controller.onSelectSizePreset = { [weak self] preset in
            self?.preferences.windowSizePreset = preset
            self?.petWindow?.applySizePreset(preset)
            if self?.miniModeController?.isEnabled == true {
                self?.miniModeController?.handleSizeChange()
            } else {
                self?.persistPetWindowPosition()
            }
            self?.bubbleStack.repositionBubbles()
        }
        controller.onToggleMiniMode = { [weak self] enabled in
            guard let self else {
                return
            }

            if enabled {
                self.miniModeController?.enterViaMenu()
            } else {
                self.miniModeController?.exit()
            }
        }
        controller.onToggleDoNotDisturb = { [weak self] enabled in
            self?.stateMachine?.setDoNotDisturbEnabled(enabled)
            self?.preferences.doNotDisturbEnabled = enabled
        }
        controller.onToggleBubbleFollow = { [weak self] enabled in
            self?.isBubbleFollowEnabled = enabled
            self?.preferences.bubbleFollowPet = enabled
            self?.bubbleStack.repositionBubbles()
        }
        controller.onToggleHideBubbles = { [weak self] enabled in
            self?.isHideBubblesEnabled = enabled
            self?.preferences.hideBubbles = enabled
            self?.updateHotKeyRegistration()
        }
        controller.onToggleSoundEffects = { [weak self] enabled in
            self?.isSoundEffectsEnabled = enabled
            self?.preferences.soundMuted = !enabled
        }
        controller.onSelectLanguage = { [weak self] language in
            self?.appLanguage = language
            self?.preferences.language = language
        }
        controller.onCheckForUpdates = { [weak self] in
            self?.checkForUpdates()
        }
        controller.onQuit = {
            NSApp.terminate(nil)
        }
        controller.onFocusSession = { session in
            TerminalFocus.focus(session.focusTarget)
        }

        statusBarController = controller
        statusItem = controller.item
        petWindow?.contextMenuProvider = { [weak controller] in
            controller?.makeMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if miniModeController?.isEnabled == true {
            preferences.windowOrigin = petWindow?.frame.origin ?? preferences.windowOrigin
        } else {
            persistPetWindowPosition()
        }
        preferences.windowSizePreset = petWindow?.sizePreset ?? preferences.windowSizePreset
        preferences.doNotDisturbEnabled = stateMachine?.doNotDisturbEnabled ?? preferences.doNotDisturbEnabled
        miniModeController?.cleanup()
        bubbleStack.stopObservingPetWindow()
        hotKeyManager.teardown()
        bubbleStack.dismissAll(respondingWith: .deny)
        httpServerTask?.cancel()
        httpServer?.stop()
        if let codexMonitor {
            Task {
                await codexMonitor.stop()
            }
        }
        stateMachine?.cleanup()
        petWebView?.teardown()
    }

    private func installTerminationSignalHandlers() {
        let signals = [SIGINT, SIGTERM]

        terminationSignalSources = signals.map { signalValue in
            signal(signalValue, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
            source.setEventHandler { [weak self] in
                self?.httpServerTask?.cancel()
                self?.httpServer?.stop()
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            return source
        }
    }

    private var currentMenuState: AppMenuState {
        AppMenuState(
            language: appLanguage,
            sizePreset: petWindow?.sizePreset ?? .small,
            isMiniModeEnabled: isMiniModeEnabled,
            isMiniTransitioning: isMiniTransitioning,
            isDoNotDisturbEnabled: stateMachine?.doNotDisturbEnabled ?? false,
            isBubbleFollowEnabled: isBubbleFollowEnabled,
            isHideBubblesEnabled: isHideBubblesEnabled,
            isSoundEffectsEnabled: isSoundEffectsEnabled,
            isPetVisible: petWindow?.isVisible ?? false,
            sessions: stateMachine?.activeSessionSnapshots ?? []
        )
    }

    private var petWebView: PetWebView? {
        petWindow?.contentView as? PetWebView
    }

    private func togglePetVisibility() {
        guard let petWindow else {
            return
        }

        if petWindow.isVisible {
            petWebView?.pauseTracking()
            petWindow.orderOut(nil)
        } else {
            petWindow.orderFrontRegardless()
            petWebView?.resumeTracking()
        }

        bubbleStack.repositionBubbles()
        updateHotKeyRegistration()
    }

    private func presentPermissionBubble(for request: PendingPermissionRequest) {
        guard let content = PermissionBubbleContent.decode(from: request.body) else {
            request.respond(with: .deny)
            return
        }

        guard request.isAwaitingDecision else {
            return
        }

        if stateMachine?.doNotDisturbEnabled == true {
            request.respond(with: .deny)
            return
        }

        if BubbleStack.passthroughTools.contains(content.toolName) {
            request.respond(with: .allow)
            return
        }

        if isHideBubblesEnabled {
            request.respond(with: .deny)
            return
        }

        bubbleStack.enqueue(content: content, request: request)
    }

    private func restorePetWindowPositionIfNeeded() {
        guard let petWindow else {
            return
        }

        // 启动恢复时优先沿用保存位置，再把窗口整体钳回当前最近的工作区。
        guard let restoredOrigin = preferences.restoredWindowOrigin(for: petWindow.frame.size) else {
            return
        }

        petWindow.setFrameOrigin(restoredOrigin)
        petWindow.clampToScreen()
    }

    private func persistPetWindowPosition() {
        guard let petWindow else {
            return
        }

        preferences.windowOrigin = petWindow.frame.origin
    }

    private func setupMiniModeController() {
        guard let petWindow, let stateMachine else {
            return
        }

        let miniMode = MiniMode(petWindow: petWindow, stateMachine: stateMachine, preferences: preferences)
        miniMode.onNeedsBubbleReposition = { [weak self] in
            self?.bubbleStack.repositionBubbles()
        }
        miniMode.onNeedsMenuRefresh = { [weak self, weak miniMode] in
            guard let self, let miniMode else {
                return
            }

            self.isMiniModeEnabled = miniMode.isEnabled
            self.isMiniTransitioning = miniMode.isTransitioning
        }
        miniMode.onDidWakeFromDND = { [weak self] in
            guard let self else {
                return
            }

            self.stateMachine?.setDoNotDisturbEnabled(false)
            self.preferences.doNotDisturbEnabled = false
            self.stateMachine?.refreshDisplayState()
        }
        miniModeController = miniMode
        miniMode.restoreFromPreferencesIfNeeded()
        isMiniModeEnabled = miniMode.isEnabled
        isMiniTransitioning = miniMode.isTransitioning
    }

    private func updateHotKeyRegistration() {
        let shouldRegister = bubbleStack.hasVisibleBubbles &&
            !isHideBubblesEnabled &&
            (petWindow?.isVisible ?? false)

        if shouldRegister {
            hotKeyManager.register()
        } else {
            hotKeyManager.unregister()
        }
    }

    /// /state 只接受轻量 JSON，先在这里做字段清洗，再交给 StateMachine 聚合。
    @MainActor
    private static func handleStateRequest(_ body: Data, using stateMachine: StateMachine) -> HTTPResponse {
        guard
            let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let rawState = payload["state"] as? String,
            let state = PetState(rawValue: rawState)
        else {
            return errorResponse(statusCode: 400, message: "unknown state")
        }

        let sessionId = (payload["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = payload["event"] as? String
        let svgUpdate = extractSVGUpdate(from: payload)
        let sourcePid = normalizedPID(payload["source_pid"])
        let cwd = normalizedString(payload["cwd"] as? String)
        let editor = normalizedEditor(payload["editor"] as? String)
        let agentId = normalizedString(payload["agent_id"] as? String)
        let headless = payload["headless"] as? Bool ?? false

        switch svgUpdate {
        case .unspecified:
            stateMachine.setState(
                state,
                sessionId: sessionId ?? "default",
                event: event,
                svg: nil,
                svgWasProvided: false,
                sourcePid: sourcePid,
                cwd: cwd,
                editor: editor,
                agentId: agentId,
                headless: headless
            )
        case .explicit(let svg):
            stateMachine.setState(
                state,
                sessionId: sessionId ?? "default",
                event: event,
                svg: svg,
                svgWasProvided: true,
                sourcePid: sourcePid,
                cwd: cwd,
                editor: editor,
                agentId: agentId,
                headless: headless
            )
        case .invalid:
            return errorResponse(statusCode: 400, message: "invalid svg payload")
        }

        return okResponse(["ok": true])
    }

    private static func normalizedPID(_ value: Any?) -> pid_t? {
        guard let number = value as? NSNumber, number.intValue > 0 else {
            return nil
        }

        return pid_t(number.intValue)
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedEditor(_ value: String?) -> FocusEditor? {
        guard let normalized = normalizedString(value) else {
            return nil
        }

        return FocusEditor(rawValue: normalized)
    }

    private func focusCurrentSession() {
        guard let target = stateMachine?.currentDisplayFocusTarget else {
            return
        }

        TerminalFocus.focus(target)
    }

    private func checkForUpdates() {
        if gitUpdater?.isAvailable == true {
            checkForGitUpdates()
            return
        }

        sparkleUpdater?.checkForUpdates()
    }

    private func checkForGitUpdates() {
        guard let gitUpdater else {
            return
        }

        Task.detached(priority: .userInitiated) { [gitUpdater, weak self] in
            do {
                let result = try await gitUpdater.checkForUpdates()
                await MainActor.run { [weak self] in
                    guard let self else {
                        return
                    }

                    if result.isUpdateAvailable {
                        self.presentGitUpdatePrompt(using: gitUpdater, result: result)
                    } else {
                        self.presentInfoAlert(
                            title: self.updateString(zh: "当前已是最新版本", en: "You’re up to date"),
                            message: self.updateString(
                                zh: "本地提交 \(result.localRevision.prefix(7)) 已和 origin/main 同步。",
                                en: "Local commit \(result.localRevision.prefix(7)) already matches origin/main."
                            )
                        )
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else {
                        return
                    }

                    self.presentErrorAlert(
                        title: self.updateString(zh: "检查更新失败", en: "Failed to check for updates"),
                        error: error
                    )
                }
            }
        }
    }

    private func presentGitUpdatePrompt(using gitUpdater: GitUpdater, result: GitUpdateCheckResult) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = updateString(zh: "发现源码更新", en: "Source update available")
        alert.informativeText = updateString(
            zh: "本地 \(result.localRevision.prefix(7))，远端 \(result.remoteRevision.prefix(7))。继续后会执行 git pull 并重启应用。",
            en: "Local \(result.localRevision.prefix(7)), remote \(result.remoteRevision.prefix(7)). Continue to run git pull and relaunch the app."
        )
        alert.addButton(withTitle: updateString(zh: "更新并重启", en: "Update and Relaunch"))
        alert.addButton(withTitle: updateString(zh: "取消", en: "Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        performGitUpdate(using: gitUpdater)
    }

    private func performGitUpdate(using gitUpdater: GitUpdater) {
        Task.detached(priority: .userInitiated) { [gitUpdater, weak self] in
            do {
                _ = try await gitUpdater.update()
                await MainActor.run { [weak self] in
                    guard let self else {
                        return
                    }

                    self.relaunchApplication()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else {
                        return
                    }

                    self.presentErrorAlert(
                        title: self.updateString(zh: "更新失败", en: "Update failed"),
                        error: error
                    )
                }
            }
        }
    }

    private func relaunchApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // 先启动当前 bundle，再退出当前进程，避免更新完成后桌宠直接消失。
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.presentErrorAlert(
                        title: self.updateString(zh: "重启失败", en: "Failed to relaunch"),
                        error: error
                    )
                    return
                }

                NSApp.terminate(nil)
            }
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: updateString(zh: "好", en: "OK"))
        alert.runModal()
    }

    private func presentErrorAlert(title: String, error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.messageText = title
        alert.runModal()
    }

    private func updateString(zh: String, en: String) -> String {
        appLanguage == .zh ? zh : en
    }

    private static func okResponse(_ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "application/json",
                "x-clawd-server": "hey-clawd",
            ],
            body: (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        )
    }

    private static func errorResponse(statusCode: Int, message: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: [
                "Content-Type": "application/json",
                "x-clawd-server": "hey-clawd",
            ],
            body: (try? JSONSerialization.data(withJSONObject: ["error": message], options: [])) ?? Data("{}".utf8)
        )
    }

}

private enum SVGUpdate {
    case unspecified
    case explicit(String?)
    case invalid
}

private extension AppDelegate {
    static func extractSVGUpdate(from payload: [String: Any]) -> SVGUpdate {
        if payload.keys.contains("display_svg") {
            return decodeSVGField(payload["display_svg"])
        }

        if payload.keys.contains("svg") {
            return decodeSVGField(payload["svg"])
        }

        return .unspecified
    }

    static func decodeSVGField(_ value: Any?) -> SVGUpdate {
        if value is NSNull {
            return .explicit(nil)
        }

        guard let string = value as? String else {
            return .invalid
        }

        let basename = URL(fileURLWithPath: string).lastPathComponent
        return .explicit(basename.isEmpty ? nil : basename)
    }
}
