import AppKit
import Foundation

enum PetState: String, CaseIterable, Sendable {
    case sleeping = "sleeping"
    case idle = "idle"
    case thinking = "thinking"
    case working = "working"
    case juggling = "juggling"
    case carrying = "carrying"
    case attention = "attention"
    case sweeping = "sweeping"
    case notification = "notification"
    case error = "error"
    case yawning = "yawning"
    case dozing = "dozing"
    case collapsing = "collapsing"
    case waking = "waking"
    case miniIdle = "mini-idle"
    case miniEnter = "mini-enter"
    case miniPeek = "mini-peek"
    case miniAlert = "mini-alert"
    case miniHappy = "mini-happy"
    case miniCrabwalk = "mini-crabwalk"
    case miniEnterSleep = "mini-enter-sleep"
    case miniSleep = "mini-sleep"

    var priority: Int {
        switch self {
        case .error:
            return 8
        case .notification, .miniAlert:
            return 7
        case .sweeping:
            return 6
        case .attention, .miniHappy:
            return 5
        case .juggling, .carrying, .miniCrabwalk:
            return 4
        case .working:
            return 3
        case .thinking:
            return 2
        case .idle, .miniIdle, .miniEnter, .miniPeek:
            return 1
        case .sleeping, .yawning, .dozing, .collapsing, .waking, .miniEnterSleep, .miniSleep:
            return 0
        }
    }

    var isOneShot: Bool {
        switch self {
        case .attention, .error, .sweeping, .notification, .carrying:
            return true
        default:
            return false
        }
    }

    var isSleepSequence: Bool {
        switch self {
        case .yawning, .dozing, .collapsing, .sleeping, .waking:
            return true
        default:
            return false
        }
    }
}

private struct PendingTransition {
    let state: PetState
    let svg: String
}

private enum SleepMode: Equatable {
    case awake
    case idleAnimation(String)
    case yawning
    case dozing
    case collapsing
    case sleeping
    case waking

    var isSleepSequenceActive: Bool {
        switch self {
        case .yawning, .dozing, .collapsing, .sleeping, .waking:
            return true
        default:
            return false
        }
    }
}

/// 复刻原版状态机的会话聚合逻辑。
/// 这里不直接关心网络和 UI，只负责根据会话集决定当前该显示哪个状态和 SVG。
@MainActor
final class StateMachine {
    private static let soundEffects: [PetState: String] = [
        .attention: "complete.mp3",
        .miniHappy: "complete.mp3",
        .notification: "confirm.mp3",
        .miniAlert: "confirm.mp3",
    ]

    static let stateSVGs: [PetState: String] = [
        .idle: "clawd-idle-follow.svg",
        .thinking: "clawd-working-thinking.svg",
        .working: "clawd-working-typing.svg",
        .juggling: "clawd-working-juggling.svg",
        .sweeping: "clawd-working-sweeping.svg",
        .error: "clawd-error.svg",
        .attention: "clawd-happy.svg",
        .notification: "clawd-notification.svg",
        .carrying: "clawd-working-carrying.svg",
        .sleeping: "clawd-sleeping.svg",
        .yawning: "clawd-idle-yawn.svg",
        .dozing: "clawd-idle-doze.svg",
        .collapsing: "clawd-collapse-sleep.svg",
        .waking: "clawd-wake.svg",
        .miniIdle: "clawd-mini-idle.svg",
        .miniEnter: "clawd-mini-enter.svg",
        .miniPeek: "clawd-mini-peek.svg",
        .miniAlert: "clawd-mini-alert.svg",
        .miniHappy: "clawd-mini-happy.svg",
        .miniCrabwalk: "clawd-mini-crabwalk.svg",
        .miniEnterSleep: "clawd-mini-enter-sleep.svg",
        .miniSleep: "clawd-mini-sleep.svg",
    ]

    static let minDisplayMs: [PetState: Int] = [
        .attention: 4_000,
        .error: 5_000,
        .sweeping: 5_500,
        .notification: 2_500,
        .carrying: 3_000,
        .working: 1_000,
        .thinking: 1_000,
        .miniAlert: 4_000,
        .miniHappy: 4_000,
    ]

    static let autoReturnMs: [PetState: Int] = [
        .attention: 4_000,
        .error: 5_000,
        .sweeping: 300_000,
        .notification: 2_500,
        .carrying: 3_000,
        .miniAlert: 4_000,
        .miniHappy: 4_000,
    ]

    static let oneShotStates: Set<PetState> = [
        .attention, .error, .sweeping, .notification, .carrying
    ]

    static let allowedDisplaySvgs: Set<String> = [
        "clawd-working-typing.svg",
        "clawd-working-building.svg",
        "clawd-working-juggling.svg",
        "clawd-working-conducting.svg",
        "clawd-idle-reading.svg",
        "clawd-idle-look.svg",
        "clawd-working-debugger.svg",
        "clawd-working-thinking.svg",
    ]

    static let idleAnims: [(svg: String, durationMs: Int)] = [
        ("clawd-idle-look.svg", 6_500),
        ("clawd-working-debugger.svg", 14_000),
        ("clawd-idle-reading.svg", 14_000),
    ]

    private static let maxSessions = 20
    private static let staleCleanupInterval: TimeInterval = 10
    private static let sessionStaleInterval: TimeInterval = 600
    private static let workingStaleInterval: TimeInterval = 300
    private static let pointerPollInterval: TimeInterval = 0.2
    private static let idleAnimationDelay: TimeInterval = 20
    private static let yawnDelay: TimeInterval = 60
    private static let dozingDelay: TimeInterval = 3
    private static let deepSleepDelay: TimeInterval = 600
    private static let collapseDelay: TimeInterval = 0.8
    private static let wakingDelay: TimeInterval = 1.5
    private static let pointerMovementThreshold: CGFloat = 0.5

    private(set) var currentState: PetState = .idle
    private(set) var currentSvg: String = StateMachine.stateSVGs[.idle] ?? "clawd-idle-follow.svg"
    /// 点击桌宠时拿它来做“聚焦当前会话终端”的目标。
    /// 这里返回的是当前聚合结果对应的胜出会话，而不是所有会话里最新的一条。
    var currentDisplaySourcePid: pid_t? {
        winningVisibleSession()?.sourcePid
    }
    var currentDisplayFocusTarget: TerminalFocusTarget? {
        guard let session = winningVisibleSession() else {
            return nil
        }

        return TerminalFocusTarget(pid: session.sourcePid, cwd: session.cwd, editor: session.editor)
    }
    var activeSessionSnapshots: [SessionMenuSnapshot] {
        sessions.values
            .filter { !$0.headless }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map {
                SessionMenuSnapshot(
                    id: $0.id,
                    state: $0.state,
                    updatedAt: $0.updatedAt,
                    sourcePid: $0.sourcePid,
                    cwd: $0.cwd,
                    editor: $0.editor,
                    agentId: $0.agentId
                )
            }
    }
    private(set) var doNotDisturbEnabled = false

    var onStateChange: ((PetState, String, pid_t?) -> Void)?

    private let soundPlayer = SoundPlayer.shared
    private var sessions: [String: Session] = [:]
    private var stateChangedAt = Date()
    private var pendingTransition: PendingTransition?
    private var pendingTimer: Timer?
    private var autoReturnTimer: Timer?
    private var staleCleanupTimer: Timer?
    /// 鼠标静止检测和唤醒都走这一套轮询，避免现在就把 Phase 3 的 EyeTracker 提前接进来。
    private var sleepMonitorTimer: Timer?
    /// 睡眠序列是单线程状态机，任意时刻只保留一个下一跳定时器。
    private var sleepStageTimer: Timer?
    private var sleepMode: SleepMode = .awake
    private var lastPointerLocation: NSPoint?
    private var lastPointerMovedAt = Date()

    init() {
        startStaleCleanup()
        startSleepMonitor()
    }

    func cleanup() {
        pendingTimer?.invalidate()
        autoReturnTimer?.invalidate()
        staleCleanupTimer?.invalidate()
        sleepMonitorTimer?.invalidate()
        sleepStageTimer?.invalidate()
        pendingTimer = nil
        autoReturnTimer = nil
        staleCleanupTimer = nil
        sleepMonitorTimer = nil
        sleepStageTimer = nil
        pendingTransition = nil
    }

    /// DND 是一个显示层覆盖态。
    /// 会话数据照常积累，醒来后直接回到当前真实状态，不丢上下文。
    func setDoNotDisturbEnabled(_ enabled: Bool) {
        guard doNotDisturbEnabled != enabled else {
            return
        }

        doNotDisturbEnabled = enabled
        cancelSleepStageTimer()

        if enabled {
            requestDisplayTransition(to: .sleeping, svgOverride: svgOverride(for: .sleeping))
            return
        }

        lastPointerMovedAt = Date()
        let displayState = resolveDisplayState()
        requestDisplayTransition(to: displayState, svgOverride: svgOverride(for: displayState))
    }

    func setState(
        _ state: PetState,
        sessionId: String = "default",
        event: String? = nil,
        svg: String? = nil,
        svgWasProvided: Bool = false,
        sourcePid: pid_t? = nil,
        cwd: String? = nil,
        editor: FocusEditor? = nil,
        agentId: String? = nil,
        headless: Bool = false
    ) {
        // 任何 hook 事件都视为“用户/会话仍在活动”，先打断本地睡眠链路，再按正常状态机处理。
        if !doNotDisturbEnabled {
            interruptSleepSequenceForExternalEvent()
        }

        let normalizedSessionId = sessionId.isEmpty ? "default" : sessionId
        let existing = sessions[normalizedSessionId]
        let nextSourcePid = sourcePid ?? existing?.sourcePid
        let nextCwd = normalizedString(cwd) ?? existing?.cwd
        let nextEditor = editor ?? existing?.editor
        let nextAgentId = normalizedString(agentId) ?? existing?.agentId
        let nextHeadless = headless || (existing?.headless ?? false)

        if sessions[normalizedSessionId] == nil, sessions.count >= Self.maxSessions {
            evictOldestSession()
        }

        if event == "PermissionRequest" {
            if !doNotDisturbEnabled {
                requestDisplayTransition(to: .notification, svgOverride: svgOverride(for: .notification))
            }
            return
        }

        if event == "SessionEnd" {
            sessions.removeValue(forKey: normalizedSessionId)
            pruneStaleSessions(shouldTransition: false)

            if doNotDisturbEnabled {
                return
            }

            if state == .sweeping {
                requestDisplayTransition(to: .sweeping, svgOverride: svgOverride(for: .sweeping))
            } else {
                let displayState = resolveDisplayState()
                requestDisplayTransition(to: displayState, svgOverride: svgOverride(for: displayState))
            }
            return
        }

        if state.isOneShot || state.isSleepSequence {
            sessions[normalizedSessionId] = Session(
                id: normalizedSessionId,
                state: .idle,
                updatedAt: Date(),
                displaySvg: nil,
                sourcePid: nextSourcePid,
                cwd: nextCwd,
                editor: nextEditor,
                agentId: nextAgentId,
                headless: nextHeadless
            )
        } else if
            let existing,
            existing.state == .juggling,
            state == .working,
            !isSubagentStop(event)
        {
            var updated = existing
            updated.updatedAt = Date()
            updated.displaySvg = pickDisplaySvg(
                for: .juggling,
                existing: existing,
                incoming: svg,
                svgWasProvided: svgWasProvided
            )
            updated.sourcePid = nextSourcePid
            updated.cwd = nextCwd
            updated.editor = nextEditor
            updated.agentId = nextAgentId
            updated.headless = nextHeadless
            sessions[normalizedSessionId] = updated
        } else {
            sessions[normalizedSessionId] = Session(
                id: normalizedSessionId,
                state: state,
                updatedAt: Date(),
                displaySvg: pickDisplaySvg(
                    for: state,
                    existing: existing,
                    incoming: svg,
                    svgWasProvided: svgWasProvided
                ),
                sourcePid: nextSourcePid,
                cwd: nextCwd,
                editor: nextEditor,
                agentId: nextAgentId,
                headless: nextHeadless
            )
        }

        pruneStaleSessions(shouldTransition: false)

        if doNotDisturbEnabled {
            return
        }

        if state.isOneShot {
            requestDisplayTransition(to: state, svgOverride: svgOverride(for: state))
            return
        }

        let displayState = resolveDisplayState()
        requestDisplayTransition(to: displayState, svgOverride: svgOverride(for: displayState))
    }

    private func startSleepMonitor() {
        sleepMonitorTimer?.invalidate()
        lastPointerLocation = NSEvent.mouseLocation
        lastPointerMovedAt = Date()

        let timer = Timer.scheduledTimer(withTimeInterval: Self.pointerPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollSleepSequence()
            }
        }

        sleepMonitorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startStaleCleanup() {
        staleCleanupTimer?.invalidate()
        staleCleanupTimer = Timer.scheduledTimer(withTimeInterval: Self.staleCleanupInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneStaleSessions(shouldTransition: true)
            }
        }

        if let staleCleanupTimer {
            RunLoop.main.add(staleCleanupTimer, forMode: .common)
        }
    }

    private func evictOldestSession() {
        let oldest = sessions.min { $0.value.updatedAt < $1.value.updatedAt }
        if let oldest {
            sessions.removeValue(forKey: oldest.key)
        }
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 睡眠序列只在“当前没有高优先级会话占住屏幕”时运行。
    /// dozing/sleeping 本身是 display-only 状态，所以要额外放行当前处于睡眠链路的情况。
    private func canAdvanceSleepSequence() -> Bool {
        if sleepMode.isSleepSequenceActive {
            return true
        }

        let resolvedState = resolveDisplayState()
        return resolvedState == .idle && currentState == .idle
    }

    private func isSubagentStop(_ event: String?) -> Bool {
        event == "SubagentStop" || event == "subagentStop"
    }

    private func pollSleepSequence() {
        guard !doNotDisturbEnabled else {
            return
        }

        let pointer = NSEvent.mouseLocation
        let now = Date()

        defer {
            lastPointerLocation = pointer
        }

        guard let lastPointerLocation else {
            self.lastPointerLocation = pointer
            lastPointerMovedAt = now
            return
        }

        if pointerMoved(from: lastPointerLocation, to: pointer) {
            lastPointerMovedAt = now
            handlePointerMovement()
            return
        }

        guard canAdvanceSleepSequence() else {
            if currentState == .idle, currentSvg != defaultSvg(for: .idle) {
                requestDisplayTransition(to: .idle, svgOverride: svgOverride(for: .idle))
            }
            sleepMode = .awake
            cancelSleepStageTimer()
            return
        }

        let inactiveFor = now.timeIntervalSince(lastPointerMovedAt)

        if inactiveFor >= Self.yawnDelay {
            if !sleepMode.isSleepSequenceActive {
                beginYawning()
            }
            return
        }

        if inactiveFor >= Self.idleAnimationDelay, sleepMode == .awake {
            beginIdleAnimation()
        }
    }

    private func pointerMoved(from oldPoint: NSPoint, to newPoint: NSPoint) -> Bool {
        abs(oldPoint.x - newPoint.x) > Self.pointerMovementThreshold ||
            abs(oldPoint.y - newPoint.y) > Self.pointerMovementThreshold
    }

    private func handlePointerMovement() {
        switch sleepMode {
        case .idleAnimation:
            sleepMode = .awake
            cancelSleepStageTimer()
            requestDisplayTransition(to: .idle, svgOverride: svgOverride(for: .idle))
        case .yawning, .dozing, .collapsing, .sleeping:
            wakeFromSleepSequence()
        case .waking, .awake:
            break
        }
    }

    private func interruptSleepSequenceForExternalEvent() {
        lastPointerMovedAt = Date()
        sleepMode = .awake
        cancelSleepStageTimer()
    }

    private func beginIdleAnimation() {
        guard let nextIdleAnim = Self.idleAnims.randomElement() else {
            return
        }

        sleepMode = .idleAnimation(nextIdleAnim.svg)
        requestDisplayTransition(to: .idle, svgOverride: nextIdleAnim.svg)
        scheduleSleepStageTimer(after: Double(nextIdleAnim.durationMs) / 1000.0) { [weak self] in
            guard
                let self,
                case .idleAnimation = self.sleepMode
            else {
                return
            }

            self.sleepMode = .awake
            self.requestDisplayTransition(to: .idle, svgOverride: self.svgOverride(for: .idle))
        }
    }

    private func beginYawning() {
        sleepMode = .yawning
        requestDisplayTransition(to: .yawning, svgOverride: svgOverride(for: .yawning))
        scheduleSleepStageTimer(after: Self.dozingDelay) { [weak self] in
            self?.beginDozing()
        }
    }

    private func beginDozing() {
        sleepMode = .dozing
        requestDisplayTransition(to: .dozing, svgOverride: svgOverride(for: .dozing))
        scheduleSleepStageTimer(after: Self.deepSleepDelay) { [weak self] in
            self?.beginCollapsing()
        }
    }

    private func beginCollapsing() {
        sleepMode = .collapsing
        requestDisplayTransition(to: .collapsing, svgOverride: svgOverride(for: .collapsing))
        scheduleSleepStageTimer(after: Self.collapseDelay) { [weak self] in
            self?.beginSleeping()
        }
    }

    private func beginSleeping() {
        sleepMode = .sleeping
        cancelSleepStageTimer()
        requestDisplayTransition(to: .sleeping, svgOverride: svgOverride(for: .sleeping))
    }

    private func wakeFromSleepSequence() {
        sleepMode = .waking
        requestDisplayTransition(to: .waking, svgOverride: svgOverride(for: .waking))
        scheduleSleepStageTimer(after: Self.wakingDelay) { [weak self] in
            guard let self else {
                return
            }

            self.sleepMode = .awake
            self.requestDisplayTransition(to: .idle, svgOverride: self.svgOverride(for: .idle))
        }
    }

    private func scheduleSleepStageTimer(after delay: TimeInterval, perform action: @escaping @MainActor () -> Void) {
        cancelSleepStageTimer()

        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in
                action()
            }
        }

        sleepStageTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelSleepStageTimer() {
        sleepStageTimer?.invalidate()
        sleepStageTimer = nil
    }

    private func pickDisplaySvg(
        for state: PetState,
        existing: Session?,
        incoming: String?,
        svgWasProvided: Bool
    ) -> String? {
        guard state == .working || state == .thinking || state == .juggling else {
            return nil
        }

        if svgWasProvided {
            guard let incoming = normalizedString(incoming) else {
                return nil
            }

            return Self.allowedDisplaySvgs.contains(incoming) ? incoming : existing?.displaySvg
        }

        return existing?.displaySvg
    }

    private func pruneStaleSessions(shouldTransition: Bool) {
        let now = Date()
        var didChange = false

        for (id, session) in sessions {
            let age = now.timeIntervalSince(session.updatedAt)

            if age > Self.sessionStaleInterval {
                sessions.removeValue(forKey: id)
                didChange = true
                continue
            }

            if age > Self.workingStaleInterval,
               session.state == .working || session.state == .thinking || session.state == .juggling {
                var updated = session
                updated.state = .idle
                updated.displaySvg = nil
                sessions[id] = updated
                didChange = true
            }
        }

        guard didChange, shouldTransition else {
            return
        }

        let displayState = resolveDisplayState()
        requestDisplayTransition(to: displayState, svgOverride: svgOverride(for: displayState))
    }

    private func resolveDisplayState() -> PetState {
        winningVisibleSession()?.state ?? .idle
    }

    private func winningVisibleSession() -> Session? {
        let visibleSessions = sessions.values.filter { !$0.headless }
        guard !visibleSessions.isEmpty else {
            return nil
        }

        return visibleSessions.max { lhs, rhs in
            if lhs.state.priority == rhs.state.priority {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.state.priority < rhs.state.priority
        }
    }

    private func requestDisplayTransition(to state: PetState, svgOverride: String?) {
        let nextSvg = svgOverride ?? defaultSvg(for: state)

        if let pendingTransition, pendingTransition.state.priority > state.priority {
            return
        }

        let sameState = state == currentState
        let sameSvg = nextSvg == currentSvg
        if sameState, sameSvg {
            return
        }

        let minDisplay = state.isSleepSequence ? 0 : (Self.minDisplayMs[currentState] ?? 0)
        let elapsed = Date().timeIntervalSince(stateChangedAt)
        let remaining = (Double(minDisplay) / 1000.0) - elapsed

        if remaining > 0 {
            // 当前动画还在最小展示窗口内时，只保留最后一个更高优先级请求。
            pendingTimer?.invalidate()
            pendingTransition = PendingTransition(state: state, svg: nextSvg)
            autoReturnTimer?.invalidate()
            autoReturnTimer = nil

            let timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }

                    self.pendingTimer = nil
                    let queued = self.pendingTransition
                    self.pendingTransition = nil

                    if let queued, queued.state.isOneShot {
                        self.applyTransition(to: queued.state, svg: queued.svg)
                    } else {
                        let resolvedState = self.resolveDisplayState()
                        self.requestDisplayTransition(to: resolvedState, svgOverride: self.svgOverride(for: resolvedState))
                    }
                }
            }

            pendingTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }

        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingTransition = nil
        applyTransition(to: state, svg: nextSvg)
    }

    private func applyTransition(to state: PetState, svg: String) {
        currentState = state
        currentSvg = svg
        stateChangedAt = Date()

        // 音效跟“最终真的显示出来的状态”绑定，而不是跟输入事件绑定。
        // 这样最小展示时长、优先级覆盖、自动回退都不会让声音和画面错位。
        if let soundName = Self.soundEffects[state] {
            soundPlayer.play(soundName)
        }

        onStateChange?(state, svg, currentDisplaySourcePid)

        autoReturnTimer?.invalidate()
        autoReturnTimer = nil

        guard let autoReturnMs = Self.autoReturnMs[state] else {
            return
        }

        // 一次性状态展示结束后，不记住它本身，而是回到当前会话集合算出来的结果。
        let timer = Timer.scheduledTimer(withTimeInterval: Double(autoReturnMs) / 1000.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.autoReturnTimer = nil
                let resolvedState = self.resolveDisplayState()
                self.requestDisplayTransition(to: resolvedState, svgOverride: self.svgOverride(for: resolvedState))
            }
        }

        autoReturnTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func svgOverride(for state: PetState) -> String? {
        switch state {
        case .idle:
            return Self.stateSVGs[.idle]
        case .working:
            return winningDisplaySvg(for: .working) ?? workingSvg()
        case .juggling:
            return winningDisplaySvg(for: .juggling) ?? jugglingSvg()
        case .thinking:
            return winningDisplaySvg(for: .thinking) ?? Self.stateSVGs[.thinking]
        default:
            return Self.stateSVGs[state]
        }
    }

    private func defaultSvg(for state: PetState) -> String {
        svgOverride(for: state) ?? Self.stateSVGs[.idle] ?? "clawd-idle-follow.svg"
    }

    private func workingSvg() -> String {
        let activeCount = sessions.values.reduce(into: 0) { count, session in
            guard !session.headless else {
                return
            }

            if session.state == .working {
                count += 1
            }
        }

        switch activeCount {
        case 3...:
            return "clawd-working-building.svg"
        case 2:
            return "clawd-working-juggling.svg"
        default:
            return "clawd-working-typing.svg"
        }
    }

    private func jugglingSvg() -> String {
        let activeCount = sessions.values.reduce(into: 0) { count, session in
            if !session.headless, session.state == .juggling {
                count += 1
            }
        }

        return activeCount >= 2 ? "clawd-working-conducting.svg" : "clawd-working-juggling.svg"
    }

    private func winningDisplaySvg(for state: PetState) -> String? {
        let winner = sessions.values
            .filter { !$0.headless && $0.state == state && $0.displaySvg != nil }
            .max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }

        guard let svg = winner?.displaySvg, Self.allowedDisplaySvgs.contains(svg) else {
            return nil
        }

        return svg
    }
}
