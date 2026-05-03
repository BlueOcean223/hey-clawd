import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let sparkleUpdaterEnabledKey = "ClawdEnableSparkleUpdater"
    private static let alertIconImage = makeAlertIconImage()
    private static let terminalApprovalEvents: Set<String> = [
        "PostToolUse",
        "PostToolUseFailure",
        "PostToolBatch",
    ]
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
    private var isAutoFocusEnabled: Bool
    private var miniModeController: MiniMode?
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
        isAutoFocusEnabled = preferences.autoFocusSession
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 配合 Info.plist LSUIElement=true，隐藏 Dock 图标
        NSApp.setActivationPolicy(.accessory)

        // 创建桌面宠物窗口并显示
        petWindow = PetWindow(sizePercent: preferences.windowSizePercent)
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
            self?.bubbleStack.allowLatestBubbleRestoringFocus()
        }
        hotKeyManager.onDeny = { [weak self] in
            self?.bubbleStack.denyLatestBubbleRestoringFocus()
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
    /// 再由 PetWindow/PetView 把结果推到界面层。
    @MainActor
    private func assembleCoreLoop() {
        let stateMachine = StateMachine()
        petWindow?.onDragStateChange = { [weak stateMachine] isDragging in
            stateMachine?.setPointerPollingSuspended(isDragging)
        }
        stateMachine.onStateChange = { [weak self, weak petWindow = self.petWindow] state, svg, sourcePid in
            petWindow?.display(state: state, svgFilename: svg, sourcePid: sourcePid)

            if state == .attention || state == .notification {
                if self?.isAutoFocusEnabled == true {
                    self?.focusCurrentSession()
                }
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
        server.setStateRequestHandler { [weak self, weak stateMachine] body in
            guard let self, let stateMachine else {
                return Self.errorResponse(statusCode: 503, message: "state handler unavailable")
            }

            return self.handleStateRequest(body, using: stateMachine)
        }
        server.setPermissionRequestHandler { [weak self] request in
            Task { @MainActor [weak self] in
                guard let self else {
                    request.respond(with: .simple(.deny))
                    return
                }

                self.presentPermissionBubble(for: request)
            }
        }
        server.setDebugSVGHandler { [weak stateMachine, weak petWindow = self.petWindow] svgFilename in
            stateMachine?.debugFreezeDisplay = true
            petWindow?.display(state: .idle, svgFilename: svgFilename, sourcePid: nil)
            return Self.okResponse(["ok": true, "svg": svgFilename])
        }
        server.setDebugResetHandler { [weak stateMachine, weak petWindow = self.petWindow] in
            stateMachine?.debugFreezeDisplay = false
            let idleSvg = StateMachine.stateSVGs[.idle] ?? "clawd-idle-follow.svg"
            petWindow?.display(state: .idle, svgFilename: idleSvg, sourcePid: nil)
            return Self.okResponse(["ok": true])
        }
        httpServer = server
        httpServerTask = Task { [server] in
            guard let activePort = await server.start() else {
                return
            }

            registerHooksOnLaunch(serverPort: activePort)
        }
    }

    private func setupUpdater() {
        guard isSparkleUpdaterEnabled else {
            sparkleUpdater = nil
            return
        }

        // Sparkle 只给安装版用，源码运行不显示应用更新入口。
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
            await monitor.start()
        }
    }

    private func setupStatusBarController() {
        let controller = StatusBarController { [weak self] in
            self?.currentMenuState ?? AppMenuState(
                language: .zh,
                sizePercent: 100,
                isMiniModeEnabled: false,
                isMiniTransitioning: false,
                isDoNotDisturbEnabled: false,
                isBubbleFollowEnabled: true,
                isHideBubblesEnabled: false,
                isSoundEffectsEnabled: true,
                isAutoFocusEnabled: false,
                isPetVisible: true,
                sessions: []
            )
        }
        controller.checkForUpdatesMenuTarget = sparkleUpdater?.controller
        controller.checkForUpdatesMenuAction = sparkleUpdater?.checkForUpdatesAction
        controller.shouldShowCheckForUpdatesMenu = { [weak self] in
            self?.sparkleUpdater != nil
        }
        controller.canCheckForUpdatesMenu = { [weak self] in
            return self?.sparkleUpdater?.canCheckForUpdates ?? false
        }

        controller.onTogglePetVisibility = { [weak self] in
            self?.togglePetVisibility()
        }
        controller.onSelectSizePercent = { [weak self] percent in
            self?.applySizePercent(percent)
        }
        controller.onSelectCustomSize = { [weak self] in
            self?.showCustomSizeDialog()
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
            if enabled {
                self?.bubbleStack.dismissAll(respondingWith: .undecided)
            }
            self?.updateHotKeyRegistration()
        }
        controller.onToggleSoundEffects = { [weak self] enabled in
            self?.isSoundEffectsEnabled = enabled
            self?.preferences.soundMuted = !enabled
        }
        controller.onToggleAutoFocusSession = { [weak self] enabled in
            self?.isAutoFocusEnabled = enabled
            self?.preferences.autoFocusSession = enabled
        }
        controller.onSelectLanguage = { [weak self] language in
            self?.appLanguage = language
            self?.preferences.language = language
        }
        controller.onCheckForUpdates = { [weak self] in
            self?.checkForUpdates()
        }
        controller.onRegisterHooks = { [weak self] target in
            self?.registerHooksManually(target: target)
        }
        controller.onUnregisterHooks = { [weak self] target in
            self?.unregisterHooksManually(target: target)
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
        preferences.windowSizePercent = petWindow?.sizePercent ?? preferences.windowSizePercent
        preferences.doNotDisturbEnabled = stateMachine?.doNotDisturbEnabled ?? preferences.doNotDisturbEnabled
        miniModeController?.cleanup()
        bubbleStack.stopObservingPetWindow()
        hotKeyManager.teardown()
        bubbleStack.dismissAll(respondingWith: .undecided)
        httpServerTask?.cancel()
        httpServer?.stop()
        if let codexMonitor {
            Task {
                await codexMonitor.stop()
            }
        }
        stateMachine?.cleanup()
        petView?.teardown()
    }

    private func installTerminationSignalHandlers() {
        let signals = [SIGINT, SIGTERM]

        terminationSignalSources = signals.map { signalValue in
            signal(signalValue, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
            source.setEventHandler { [weak self] in
                self?.httpServerTask?.cancel()
                self?.httpServer?.stop()
                MainActor.assumeIsolated {
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
            sizePercent: petWindow?.sizePercent ?? 100,
            isMiniModeEnabled: isMiniModeEnabled,
            isMiniTransitioning: isMiniTransitioning,
            isDoNotDisturbEnabled: stateMachine?.doNotDisturbEnabled ?? false,
            isBubbleFollowEnabled: isBubbleFollowEnabled,
            isHideBubblesEnabled: isHideBubblesEnabled,
            isSoundEffectsEnabled: isSoundEffectsEnabled,
            isAutoFocusEnabled: isAutoFocusEnabled,
            isPetVisible: petWindow?.isVisible ?? false,
            sessions: stateMachine?.activeSessionSnapshots ?? []
        )
    }

    private var petView: PetView? {
        petWindow?.contentView as? PetView
    }

    private func makeAlert(style: NSAlert.Style? = nil) -> NSAlert {
        let alert = NSAlert()
        if let style {
            alert.alertStyle = style
        }
        alert.icon = Self.alertIconImage
        return alert
    }

    private static func makeAlertIconImage() -> NSImage {
        let imageSize: CGFloat = 64
        let pixelSize: CGFloat = 3
        let origin = CGPoint(x: 9.5, y: 8)

        let image = NSImage(size: NSSize(width: imageSize, height: imageSize), flipped: true) { _ in
            NSColor(red: 222 / 255, green: 136 / 255, blue: 109 / 255, alpha: 1).setFill()

            func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
                NSRect(
                    x: origin.x + x * pixelSize,
                    y: origin.y + y * pixelSize,
                    width: w * pixelSize,
                    height: h * pixelSize
                ).fill()
            }

            fill(2, 3, 11, 2)
            fill(2, 5, 2, 2)
            fill(5, 5, 5, 2)
            fill(11, 5, 2, 2)
            fill(2, 7, 11, 3)
            fill(0, 6, 2, 2)
            fill(13, 6, 2, 2)
            fill(3, 10, 1, 2)
            fill(5, 10, 1, 2)
            fill(9, 10, 1, 2)
            fill(11, 10, 1, 2)

            NSColor.black.withAlphaComponent(0.75).setFill()
            fill(4, 5, 1, 2)
            fill(10, 5, 1, 2)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func applySizePercent(_ percent: Int) {
        preferences.windowSizePercent = percent
        petWindow?.applySizePercent(percent)
        if miniModeController?.isEnabled == true {
            miniModeController?.handleSizeChange()
        } else {
            persistPetWindowPosition()
        }
        bubbleStack.repositionBubbles()
    }

    private func showCustomSizeDialog() {
        let alert = makeAlert()
        alert.messageText = appLanguage == .zh ? "自定义大小" : "Custom Size"
        alert.informativeText = appLanguage == .zh ? "调整百分比 (25-400):" : "Adjust percentage (25-400):"
        alert.addButton(withTitle: appLanguage == .zh ? "确定" : "OK")
        alert.addButton(withTitle: appLanguage == .zh ? "取消" : "Cancel")

        let initialPercent = petWindow?.sizePercent ?? 100
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.alignment = .center
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        valueLabel.frame = NSRect(x: 0, y: 34, width: 260, height: 18)

        let slider = NSSlider(value: Double(initialPercent), minValue: 25, maxValue: 400, target: nil, action: nil)
        slider.frame = NSRect(x: 0, y: 4, width: 210, height: 24)

        let stepper = NSStepper(frame: NSRect(x: 224, y: 2, width: 20, height: 28))
        stepper.minValue = 25
        stepper.maxValue = 400
        stepper.increment = 1
        stepper.integerValue = min(max(initialPercent, 25), 400)

        let coordinator = CustomSizeControlCoordinator(
            slider: slider,
            stepper: stepper,
            valueLabel: valueLabel,
            initialValue: initialPercent
        )
        slider.target = coordinator
        slider.action = #selector(CustomSizeControlCoordinator.sliderChanged(_:))
        stepper.target = coordinator
        stepper.action = #selector(CustomSizeControlCoordinator.stepperChanged(_:))

        accessoryView.addSubview(valueLabel)
        accessoryView.addSubview(slider)
        accessoryView.addSubview(stepper)
        alert.accessoryView = accessoryView

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        applySizePercent(coordinator.value)
    }

    private func togglePetVisibility() {
        guard let petWindow else {
            return
        }

        if petWindow.isVisible {
            petView?.pauseTracking()
            petWindow.orderOut(nil)
        } else {
            petWindow.orderFrontRegardless()
            petView?.resumeTracking()
        }

        bubbleStack.repositionBubbles()
        updateHotKeyRegistration()
    }

    private func presentPermissionBubble(for request: PendingPermissionRequest) {
        guard let content = PermissionBubbleContent.decode(from: request.body) else {
            request.respond(with: .simple(.undecided))
            return
        }

        guard request.isAwaitingDecision else {
            return
        }

        if stateMachine?.doNotDisturbEnabled == true {
            request.respond(with: .simple(.undecided))
            return
        }

        if BubbleStack.passthroughTools.contains(content.toolName) {
            request.respond(with: .simple(.allow))
            return
        }

        if isHideBubblesEnabled {
            request.respond(with: .simple(.undecided))
            return
        }

        let previous = captureFrontmostApp()
        bubbleStack.enqueue(
            content: content,
            request: request,
            previousApp: previous?.app,
            previousAppBundleId: previous?.bundleId
        )
    }

    private func captureFrontmostApp() -> (app: NSRunningApplication, bundleId: String?)? {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        guard front.activationPolicy == .regular else {
            return nil
        }

        return (front, front.bundleIdentifier)
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
    private func handleStateRequest(_ body: Data, using stateMachine: StateMachine) -> HTTPResponse {
        guard
            let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let rawState = payload["state"] as? String,
            let state = PetState(rawValue: rawState)
        else {
            return Self.errorResponse(statusCode: 400, message: "unknown state")
        }

        let sessionId = (payload["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = payload["event"] as? String
        let svgUpdate = Self.extractSVGUpdate(from: payload)
        let sourcePid = Self.normalizedPID(payload["source_pid"])
        let cwd = Self.normalizedString(payload["cwd"] as? String)
        let editor = Self.normalizedEditor(payload["editor"] as? String)
        let agentId = Self.normalizedString(payload["agent_id"] as? String)
        let headless: Bool? = payload.keys.contains("headless") ? (payload["headless"] as? Bool ?? false) : nil
        let normalizedSessionId = sessionId ?? "default"

        switch svgUpdate {
        case .unspecified:
            stateMachine.setState(
                state,
                sessionId: normalizedSessionId,
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
                sessionId: normalizedSessionId,
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
            return Self.errorResponse(statusCode: 400, message: "invalid svg payload")
        }

        autoDismissBubbleIfTerminalApproved(
            payload: payload,
            event: event,
            sessionId: normalizedSessionId,
            agentId: agentId
        )

        return Self.okResponse(["ok": true])
    }

    private func autoDismissBubbleIfTerminalApproved(
        payload: [String: Any],
        event: String?,
        sessionId: String,
        agentId: String?
    ) {
        guard
            let event,
            Self.terminalApprovalEvents.contains(event),
            agentId == "claude-code"
        else {
            return
        }

        if event == "PostToolBatch" {
            let toolCalls = payload["tool_calls"] as? [[String: Any]] ?? []
            for toolCall in toolCalls {
                dismissBubbleMatchingToolPayload(toolCall, sessionId: sessionId)
            }
            return
        }

        dismissBubbleMatchingToolPayload(payload, sessionId: sessionId)
    }

    private func dismissBubbleMatchingToolPayload(_ payload: [String: Any], sessionId: String) {
        guard
            let toolName = payload["tool_name"] as? String,
            !toolName.isEmpty,
            let toolInputHash = payload["tool_input_hash"] as? String,
            !toolInputHash.isEmpty
        else {
            return
        }

        bubbleStack.dismissBubbleMatchingTerminalApproval(
            sessionId: sessionId,
            toolName: toolName,
            toolInputHash: toolInputHash
        )
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
        sparkleUpdater?.checkForUpdates()
    }

    /// 启动时静默注册一次 hooks，不弹窗。
    private func registerHooksOnLaunch(serverPort: Int) {
        Task.detached(priority: .utility) {
            _ = HookInstaller.register(serverPort: serverPort)
        }
    }

    /// 菜单栏手动注册，完成后弹窗显示结果。
    private func registerHooksManually(target: HookInstaller.HookTarget?) {
        Task.detached(priority: .userInitiated) {
            let result: (success: Bool, output: String)
            if let target {
                result = HookInstaller.register(target: target)
            } else {
                result = HookInstaller.register()
            }
            await MainActor.run {
                let alert = self.makeAlert(style: result.success ? .informational : .warning)
                alert.messageText = result.success ? "Hooks Registered" : "Registration Failed"
                alert.informativeText = result.output
                alert.runModal()
            }
        }
    }

    /// 菜单栏手动清理钩子，完成后弹窗显示结果。
    private func unregisterHooksManually(target: HookInstaller.HookTarget?) {
        Task.detached(priority: .userInitiated) {
            let result: (success: Bool, output: String)
            if let target {
                result = HookInstaller.unregister(target: target)
            } else {
                result = HookInstaller.unregister()
            }
            await MainActor.run {
                let alert = self.makeAlert(style: result.success ? .informational : .warning)
                alert.messageText = result.success ? "Hooks Cleaned" : "Clean Failed"
                alert.informativeText = result.output
                alert.runModal()
            }
        }
    }

    private var isSparkleUpdaterEnabled: Bool {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: Self.sparkleUpdaterEnabledKey) else {
            return false
        }

        if let boolValue = rawValue as? Bool {
            return boolValue
        }

        if let numberValue = rawValue as? NSNumber {
            return numberValue.boolValue
        }

        if let stringValue = rawValue as? String {
            return NSString(string: stringValue).boolValue
        }

        return false
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

@MainActor
private final class CustomSizeControlCoordinator: NSObject {
    private let slider: NSSlider
    private let stepper: NSStepper
    private let valueLabel: NSTextField

    private(set) var value: Int

    init(slider: NSSlider, stepper: NSStepper, valueLabel: NSTextField, initialValue: Int) {
        self.slider = slider
        self.stepper = stepper
        self.valueLabel = valueLabel
        self.value = min(max(initialValue, 25), 400)
        super.init()
        updateControls(to: value)
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        updateControls(to: Int(sender.doubleValue.rounded()))
    }

    @objc func stepperChanged(_ sender: NSStepper) {
        updateControls(to: sender.integerValue)
    }

    private func updateControls(to rawValue: Int) {
        value = min(max(rawValue, 25), 400)
        slider.integerValue = value
        stepper.integerValue = value
        valueLabel.stringValue = "\(value)%"
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
