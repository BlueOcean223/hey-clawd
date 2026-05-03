import AppKit
import Foundation

/// 桌宠的全部状态。`rawValue` 与 `Resources/svg/clawd-<state>.svg` 的文件名约定一致。
/// 普通桌宠模式与 mini 模式（边缘贴附小窗）的状态分两族；
/// `priority` 决定多 hook 同时活跃时谁的状态会胜出。
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

    var isMiniState: Bool {
        rawValue.hasPrefix("mini-")
    }

    /// 状态优先级（越大越优先）。多个会话同时活跃时取最高的展示。
    /// 0 = 睡眠序列（最低，可被任何活动打断）；8 = error（最高，必须立刻让用户看到）。
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

    /// 一次性表演型状态：播完一次自动回退到上一个聚合结果。
    /// 这些状态有 `minDisplayMs` / `autoReturnMs` 控制最短停留与自动复位。
    var isOneShot: Bool {
        switch self {
        case .attention, .error, .sweeping, .notification, .carrying, .miniAlert, .miniHappy:
            return true
        default:
            return false
        }
    }

    /// 当前是否处于"睡眠链路"中的某一阶段；睡眠链路自身不应被睡眠 timer 重复触发。
    var isSleepSequence: Bool {
        switch self {
        case .yawning, .dozing, .collapsing, .sleeping, .waking:
            return true
        default:
            return false
        }
    }
}

/// 待应用的状态切换；带 `triggeringSession` 是为了在状态真正落地时把 sourcePid 一起带过去，
/// 让点击桌宠能聚焦到引发本次切换的那个会话所在终端。
private struct PendingTransition {
    let state: PetState
    let svg: String
    let triggeringSession: Session?
}

/// 单条 idle 动画的资源描述：固定时长 + 对应 SVG 文件。
struct IdleAnimationSpec: Sendable {
    let svg: String
    let durationMs: Int
}

/// 睡眠链路的内部模式。`idleAnimation` 表示在播某段 idle 表演动画，
/// 其余阶段对应 yawning → dozing → collapsing → sleeping → waking。
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

    /// 一次性状态强制最少展示这么久（毫秒），即使更高优先级的活动会话进入也要等过这段时间，
    /// 避免 attention/notification 闪现一帧就消失。
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

    /// 一次性状态在没人接管的情况下，多久后自动回到聚合状态。
    /// `sweeping` 的 5 分钟特别长——它对应 Claude Code 的 context compact 流程，整个过程都要持续显示。
    static let autoReturnMs: [PetState: Int] = [
        .attention: 4_000,
        .error: 5_000,
        .sweeping: 300_000,
        .notification: 2_500,
        .carrying: 3_000,
        .miniAlert: 4_000,
        .miniHappy: 4_000,
    ]

    /// 允许 hook 端通过 `display_svg` 显式指定的 SVG 白名单。
    /// 不在表里的 svg 名字会被忽略——避免外部输入控制任意资源加载。
    static let allowedDisplaySvgs: Set<String> = [
        "clawd-working-typing.svg",
        "clawd-working-building.svg",
        "clawd-working-juggling.svg",
        "clawd-working-conducting.svg",
        "clawd-idle-reading.svg",
        "clawd-idle-look.svg",
        "clawd-working-debugger.svg",
        "clawd-working-thinking.svg",
        "clawd-working-ultrathink.svg",
        "clawd-working-beacon.svg",
        "clawd-working-builder.svg",
        "clawd-working-confused.svg",
        "clawd-working-overheated.svg",
        "clawd-working-pushing.svg",
        "clawd-working-success.svg",
        "clawd-working-wizard.svg",
    ]

    /// 长时间 idle 时随机播放的"表演型 idle"动画清单。每条带建议时长。
    /// `idleAnimationDelay` 之后开始随机播；和 yawn/sleep 链路按时间叠加。
    static let idleAnims: [IdleAnimationSpec] = [
        IdleAnimationSpec(svg: "clawd-idle-look.svg", durationMs: 10_000),
        IdleAnimationSpec(svg: "clawd-working-debugger.svg", durationMs: 14_000),
        IdleAnimationSpec(svg: "clawd-idle-reading.svg", durationMs: 14_000),
        IdleAnimationSpec(svg: "clawd-idle-living.svg", durationMs: 16_000),
        IdleAnimationSpec(svg: "clawd-idle-music.svg", durationMs: 9_600),
        IdleAnimationSpec(svg: "clawd-idle-smoking.svg", durationMs: 16_000),
        IdleAnimationSpec(svg: "clawd-crab-walking.svg", durationMs: 8_000),
    ]

    /// 同时跟踪的会话上限；超过后剔除最旧的，避免内存无限增长。
    private static let maxSessions = 20
    /// 周期性扫描陈旧会话并清理。
    private static let staleCleanupInterval: TimeInterval = 10
    /// 一般会话超过 10 分钟无更新视为失效。
    private static let sessionStaleInterval: TimeInterval = 600
    /// "working" 是允许更长寂静期的：长任务完全可能 5 分钟都没新事件。
    private static let workingStaleInterval: TimeInterval = 300
    /// 鼠标活跃检测的轮询周期；用于判定用户是否离开。
    private static let pointerPollInterval: TimeInterval = 0.2
    /// idle 多久后开始播表演型 idle 动画。
    private static let idleAnimationDelay: TimeInterval = 20
    /// 用户离开多久开始打哈欠（睡眠链路的入口）。
    private static let yawnDelay: TimeInterval = 180
    private static let dozingDelay: TimeInterval = 3.8
    /// 进入深度睡眠的总等待时长。
    private static let deepSleepDelay: TimeInterval = 600
    private static let collapseDelay: TimeInterval = 0.8
    /// DND 触发的 collapse 比自然 collapse 慢一些，让用户看清楚动画。
    private static let dndCollapseDelay: TimeInterval = 3.6
    private static let wakingDelay: TimeInterval = 3.5
    /// 鼠标移动判定阈值；小于这个值视为静止，避免抖动算"活跃"。
    private static let pointerMovementThreshold: CGFloat = 0.5
    /// 软 idle 回归延迟：一次性状态结束到真正切回 idle 的过渡时间。
    private static let softIdleReturnDelay: TimeInterval = 0.22

    private(set) var currentState: PetState = .idle
    private(set) var currentSvg: String = StateMachine.stateSVGs[.idle] ?? "clawd-idle-follow.svg"
    /// 点击桌宠时拿它来做“聚焦当前会话终端”的目标。
    /// 这里返回的是当前聚合结果对应的胜出会话，而不是所有会话里最新的一条。
    var currentDisplaySourcePid: pid_t? {
        if currentState.isOneShot, let oneShotSourcePid {
            return oneShotSourcePid
        }

        return winningVisibleSession()?.sourcePid
    }
    var currentDisplayFocusTarget: TerminalFocusTarget? {
        if currentState.isOneShot, let oneShotFocusTarget {
            return oneShotFocusTarget
        }

        guard let session = winningVisibleSession() else {
            return nil
        }

        return session.focusTarget
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
                    sourceProcessIdentity: $0.sourceProcessIdentity,
                    sourcePidVerified: $0.sourcePidVerified,
                    agentPid: $0.agentPid,
                    pidChain: $0.pidChain,
                    cwd: $0.cwd,
                    editor: $0.editor,
                    agentId: $0.agentId
                )
            }
    }
    private(set) var doNotDisturbEnabled = false
    private(set) var miniModeEnabled = false
    private(set) var miniTransitioning = false
    private var miniPeekEnabled = false
    private var suppressExternalEvents = false

    var onStateChange: ((PetState, String, pid_t?) -> Void)?
    var onDoNotDisturbChange: ((Bool) -> Void)?
    /// Debug 模式下冻结显示输出，阻止状态机推送 SVG 变更到 PetWindow。
    var debugFreezeDisplay = false

    private let soundPlayer = SoundPlayer.shared
    private var sessions: [String: Session] = [:]
    private var stateChangedAt = Date()
    private var pendingTransition: PendingTransition?
    private var pendingTimer: Timer?
    private var softIdleTimer: Timer?
    private var softIdleTransition: PendingTransition?
    private var autoReturnTimer: Timer?
    private var staleCleanupTimer: Timer?
    /// 鼠标静止检测和唤醒都走这一套轮询，避免现在就把 Phase 3 的 EyeTracker 提前接进来。
    private var sleepMonitorTimer: Timer?
    /// 睡眠序列是单线程状态机，任意时刻只保留一个下一跳定时器。
    private var sleepStageTimer: Timer?
    private var sleepMode: SleepMode = .awake
    private var lastPointerLocation: NSPoint?
    private var lastPointerMovedAt = Date()
    private var isPointerPollingSuspended = false
    private var oneShotSourcePid: pid_t?
    private var oneShotFocusTarget: TerminalFocusTarget?
    private let processInspector: ProcessInspecting

    init(processInspector: ProcessInspecting = SystemProcessInspector.shared) {
        self.processInspector = processInspector
        startStaleCleanup()
        startSleepMonitor()
    }

    func cleanup() {
        pendingTimer?.invalidate()
        softIdleTimer?.invalidate()
        autoReturnTimer?.invalidate()
        staleCleanupTimer?.invalidate()
        sleepMonitorTimer?.invalidate()
        sleepStageTimer?.invalidate()
        pendingTimer = nil
        softIdleTimer = nil
        autoReturnTimer = nil
        staleCleanupTimer = nil
        sleepMonitorTimer = nil
        sleepStageTimer = nil
        pendingTransition = nil
        softIdleTransition = nil
    }

#if DEBUG
    func pruneStaleSessionsForTesting() {
        pruneStaleSessions(shouldTransition: false)
    }
#endif

    func setMiniModeEnabled(_ enabled: Bool) {
        miniModeEnabled = enabled

        if !enabled {
            miniTransitioning = false
            miniPeekEnabled = false
        }
    }

    func setMiniTransitioning(_ enabled: Bool) {
        miniTransitioning = enabled
    }

    func setMiniPeekEnabled(_ enabled: Bool) {
        guard miniPeekEnabled != enabled else {
            return
        }

        miniPeekEnabled = enabled

        guard miniModeEnabled, !miniTransitioning else {
            return
        }

        // mini-alert / mini-happy 展示期内不强行打断，等 auto-return 后再根据 hover 落到稳定态。
        guard currentState == .miniIdle || currentState == .miniPeek else {
            return
        }

        let nextState = stableMiniState()
        requestDisplayTransition(to: nextState, svgOverride: svgOverride(for: nextState))
    }

    func requestMiniDisplayState(_ state: PetState) {
        requestDisplayTransition(to: state, svgOverride: svgOverride(for: state))
    }

    func setPointerPollingSuspended(_ suspended: Bool) {
        guard isPointerPollingSuspended != suspended else {
            return
        }

        isPointerPollingSuspended = suspended
        lastPointerLocation = NSEvent.mouseLocation
        lastPointerMovedAt = Date()
    }

    func refreshDisplayState() {
        guard !suppressExternalEvents || miniModeEnabled else {
            return
        }

        let displayState: PetState
        if doNotDisturbEnabled {
            displayState = miniModeEnabled ? .miniSleep : .sleeping
        } else {
            displayState = resolveDisplayState()
        }

        requestDisplayTransition(to: displayState, svgOverride: svgOverride(for: displayState))
    }

    /// DND 会临时接管显示层，并在入睡/唤醒阶段吞掉外部 hook 事件。
    /// 这样桌宠不会被工作流噪音反复打断，行为更接近“真的去睡了”。
    func setDoNotDisturbEnabled(_ enabled: Bool) {
        guard doNotDisturbEnabled != enabled else {
            return
        }

        doNotDisturbEnabled = enabled
        onDoNotDisturbChange?(enabled)
        cancelSleepStageTimer()
        clearQueuedDisplayTransitions()

        if enabled {
            // DND 不是普通的“静态切 sleeping”，而是强制接管显示层并快速入睡。
            suppressExternalEvents = true
            lastPointerMovedAt = Date()

            if miniModeEnabled {
                sleepMode = .sleeping
                let sleepState: PetState = .miniSleep
                requestDisplayTransition(to: sleepState, svgOverride: svgOverride(for: sleepState))
            } else {
                beginDoNotDisturbSleepSequence()
            }
            return
        }

        lastPointerMovedAt = Date()
        if miniModeEnabled {
            suppressExternalEvents = false
            sleepMode = .awake
            let nextState = stableMiniState()
            requestDisplayTransition(to: nextState, svgOverride: svgOverride(for: nextState))
        } else {
            beginWakeFromDoNotDisturb()
        }
    }

    /// 由所有外部事件（HTTP、CodexMonitor、菜单）共同调用的写入入口。
    /// 大体流程：
    /// 1. DND/唤醒动画期间直接吞掉事件；
    /// 2. 非 DND 时打断本地睡眠链路；
    /// 3. 合并字段（incoming 字段缺失则继承现有 session）；
    /// 4. 决定是覆盖会话状态还是保留 juggling（避免 working 抢占已经在多任务中的桌宠）；
    /// 5. 一次性状态直接展示；其余状态走 `resolveDisplayState` 聚合后再展示。
    func setState(
        _ state: PetState,
        sessionId: String = "default",
        event: String? = nil,
        svg: String? = nil,
        svgWasProvided: Bool = false,
        sourcePid: pid_t? = nil,
        agentPid: pid_t? = nil,
        pidChain: [pid_t]? = nil,
        cwd: String? = nil,
        editor: FocusEditor? = nil,
        agentId: String? = nil,
        headless: Bool? = nil
    ) {
        // DND 打开和唤醒动画期间，hook 事件只会制造噪音，直接吞掉。
        guard !suppressExternalEvents else {
            return
        }

        // 任何 hook 事件都视为“用户/会话仍在活动”，先打断本地睡眠链路，再按正常状态机处理。
        if !doNotDisturbEnabled {
            interruptSleepSequenceForExternalEvent()
        }

        let normalizedSessionId = sessionId.isEmpty ? "default" : sessionId
        let existing = sessions[normalizedSessionId]
        let nextSourcePid = sourcePid ?? existing?.sourcePid
        let nextAgentPid = agentPid ?? existing?.agentPid
        let nextPidChain = normalizedPIDChain(pidChain) ?? existing?.pidChain
        let nextSourceProcessIdentity = sourceProcessIdentity(
            incomingSourcePid: sourcePid,
            resolvedSourcePid: nextSourcePid,
            existing: existing
        )
        let nextSourcePidVerified = sourcePidVerified(
            resolvedSourcePid: nextSourcePid,
            resolvedAgentPid: nextAgentPid,
            existing: existing,
            shouldRefresh: sourcePid != nil || agentPid != nil || pidChain != nil
        )
        let nextCwd = normalizedString(cwd) ?? existing?.cwd
        let nextEditor = editor ?? existing?.editor
        let nextAgentId = normalizedString(agentId) ?? existing?.agentId
        let nextHeadless: Bool
        if let headless {
            nextHeadless = headless
        } else {
            nextHeadless = existing?.headless ?? false
        }

        if sessions[normalizedSessionId] == nil, sessions.count >= Self.maxSessions {
            evictOldestSession()
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
                sourceProcessIdentity: nextSourceProcessIdentity,
                sourcePidVerified: nextSourcePidVerified,
                agentPid: nextAgentPid,
                pidChain: nextPidChain,
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
            updated.sourceProcessIdentity = nextSourceProcessIdentity
            updated.sourcePidVerified = nextSourcePidVerified
            updated.agentPid = nextAgentPid
            updated.pidChain = nextPidChain
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
                sourceProcessIdentity: nextSourceProcessIdentity,
                sourcePidVerified: nextSourcePidVerified,
                agentPid: nextAgentPid,
                pidChain: nextPidChain,
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
            requestDisplayTransition(
                to: state,
                svgOverride: svgOverride(for: state),
                triggeringSession: sessions[normalizedSessionId]
            )
            return
        }

        let displayState = resolveDisplayState()
        requestDisplayTransition(to: displayState, svgOverride: svgOverride(for: displayState))
    }

    /// 后台轮询鼠标位置，决定是否进入 yawn → doze → sleep 链路。
    /// 不依赖 EyeTracker 是为了避免 mini 模式 / 隐藏窗口情况下监听不到。
    private func startSleepMonitor() {
        sleepMonitorTimer?.invalidate()
        lastPointerLocation = NSEvent.mouseLocation
        lastPointerMovedAt = Date()

        let timer = Timer.scheduledTimer(withTimeInterval: Self.pointerPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollSleepSequence()
            }
        }

        sleepMonitorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startStaleCleanup() {
        staleCleanupTimer?.invalidate()
        staleCleanupTimer = Timer.scheduledTimer(withTimeInterval: Self.staleCleanupInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pruneStaleSessions(shouldTransition: true)
            }
        }

        if let staleCleanupTimer {
            RunLoop.main.add(staleCleanupTimer, forMode: .common)
        }
    }

    /// 移除 maxSessions 装满后的最旧会话；按 updatedAt 升序找第一个非 headless 的删除。
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

    private func normalizedPIDChain(_ value: [pid_t]?) -> [pid_t]? {
        guard let value else {
            return nil
        }

        let normalized = value.filter { $0 > 0 }
        return normalized.isEmpty ? nil : normalized
    }

    private func sourceProcessIdentity(
        incomingSourcePid: pid_t?,
        resolvedSourcePid: pid_t?,
        existing: Session?
    ) -> FocusProcessIdentity? {
        if let incomingSourcePid {
            return processInspector.captureApplicationIdentity(for: incomingSourcePid)
        }

        guard resolvedSourcePid == existing?.sourcePid else {
            return nil
        }

        return existing?.sourceProcessIdentity
    }

    /// hook 端把 source_pid + agent_pid + pid_chain 同时上送时，验证 source_pid 是否真的是
    /// agent 进程的祖先。验证通过后才允许 TerminalFocus 激活白名单外的 bundle。
    private func sourcePidVerified(
        resolvedSourcePid: pid_t?,
        resolvedAgentPid: pid_t?,
        existing: Session?,
        shouldRefresh: Bool
    ) -> Bool {
        guard let resolvedSourcePid else {
            return false
        }

        if !shouldRefresh, resolvedSourcePid == existing?.sourcePid {
            return existing?.sourcePidVerified ?? false
        }

        guard
            let resolvedAgentPid,
            processInspector.isProcessAlive(resolvedAgentPid)
        else {
            return resolvedSourcePid == existing?.sourcePid && existing?.sourcePidVerified == true
        }

        return processInspector.isAncestor(resolvedSourcePid, of: resolvedAgentPid)
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
        guard !isPointerPollingSuspended, !doNotDisturbEnabled, !miniModeEnabled else {
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

    private func clearQueuedDisplayTransitions() {
        // DND 需要立刻抢占显示层，不能被旧的一次性动画或 auto-return 拖住。
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingTransition = nil
        cancelSoftIdleTransition()
        autoReturnTimer?.invalidate()
        autoReturnTimer = nil
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

    private func beginDoNotDisturbSleepSequence() {
        beginCollapsing()
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
        let delay = doNotDisturbEnabled ? Self.dndCollapseDelay : Self.collapseDelay
        scheduleSleepStageTimer(after: delay) { [weak self] in
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

    private func beginWakeFromDoNotDisturb() {
        sleepMode = .waking
        requestDisplayTransition(to: .waking, svgOverride: svgOverride(for: .waking))
        scheduleSleepStageTimer(after: Self.wakingDelay) { [weak self] in
            guard let self else {
                return
            }

            // 唤醒阶段结束前继续屏蔽 hook，等角色回到 idle 再恢复外部事件。
            self.sleepMode = .awake
            self.suppressExternalEvents = false
            self.requestDisplayTransition(to: .idle, svgOverride: self.svgOverride(for: .idle))
        }
    }

    private func scheduleSleepStageTimer(after delay: TimeInterval, perform action: @escaping @MainActor () -> Void) {
        cancelSleepStageTimer()

        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
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

    /// 周期性扫描 sessions：超过 sessionStaleInterval / workingStaleInterval 的会话被剔除。
    /// `shouldTransition` 控制是否在剔除后立刻聚合新状态；setState 路径已经在调用方做了，传 false 跳过。
    private func pruneStaleSessions(shouldTransition: Bool) {
        let now = Date()
        var didChange = false

        for (id, session) in sessions {
            let age = now.timeIntervalSince(session.updatedAt)

            if let agentPid = session.agentPid,
               !processInspector.isProcessAlive(agentPid) {
                sessions.removeValue(forKey: id)
                didChange = true
                continue
            }

            if let sourcePid = session.sourcePid,
               session.sourceProcessIdentity != nil,
               !processInspector.isProcessAlive(sourcePid) {
                sessions.removeValue(forKey: id)
                didChange = true
                continue
            }

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

        guard !suppressExternalEvents else {
            return
        }

        let displayState = resolveDisplayState()
        requestDisplayTransition(to: displayState, svgOverride: svgOverride(for: displayState))
    }

    /// 把所有可见、非陈旧的会话按优先级聚合成"该展示哪一种状态"。
    /// mini 模式下走 `stableMiniState` 限定在 mini-* 家族里。
    private func resolveDisplayState() -> PetState {
        winningVisibleSession()?.state ?? .idle
    }

    private func stableMiniState() -> PetState {
        if doNotDisturbEnabled {
            return .miniSleep
        }

        return miniPeekEnabled ? .miniPeek : .miniIdle
    }

    private func normalizedDisplayState(_ state: PetState) -> PetState? {
        if miniTransitioning, !state.isMiniState {
            return nil
        }

        guard miniModeEnabled, !state.isMiniState else {
            return state
        }

        switch state {
        case .notification:
            return .miniAlert
        case .attention:
            return .miniHappy
        default:
            // mini 模式下其他工作态静默，不额外切动画，只维持当前稳定姿态。
            return stableMiniState()
        }
    }

    /// 决定要显示哪个会话作为"焦点"——返回最高优先级、最新的非陈旧会话。
    /// 用于点击桌宠跳转终端、菜单展示当前活跃会话等。
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

    /// 状态切换的主路径：先做 minDisplayMs 检查防抖，再决定立即应用还是排到 pendingTransition。
    /// `triggeringSession` 在落地时会作为 `oneShotSourcePid` 缓存，让点击桌宠能跳到这个会话。
    private func requestDisplayTransition(to state: PetState, svgOverride: String?, triggeringSession: Session? = nil) {
        guard !debugFreezeDisplay else {
            return
        }
        guard let effectiveState = normalizedDisplayState(state) else {
            return
        }

        let effectiveSvgOverride = effectiveState == state ? svgOverride : self.svgOverride(for: effectiveState)
        let nextSvg = effectiveSvgOverride ?? defaultSvg(for: effectiveState)

        if let pendingTransition, pendingTransition.state.priority > effectiveState.priority {
            return
        }

        let sameState = effectiveState == currentState
        let sameSvg = nextSvg == currentSvg
        if sameState, sameSvg {
            if effectiveState.isOneShot {
                applyTransition(to: effectiveState, svg: nextSvg, triggeringSession: triggeringSession)
            }
            return
        }

        if !shouldSoftDelayIdleTransition(to: effectiveState, svg: nextSvg) {
            cancelSoftIdleTransition()
        }

        let minDisplay = effectiveState.isSleepSequence ? 0 : (Self.minDisplayMs[currentState] ?? 0)
        let elapsed = Date().timeIntervalSince(stateChangedAt)
        let remaining = (Double(minDisplay) / 1000.0) - elapsed

        if remaining > 0 {
            // 当前动画还在最小展示窗口内时，只保留最后一个更高优先级请求。
            pendingTimer?.invalidate()
            pendingTransition = PendingTransition(state: effectiveState, svg: nextSvg, triggeringSession: triggeringSession)
            autoReturnTimer?.invalidate()
            autoReturnTimer = nil

            let timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }

                    self.pendingTimer = nil
                    let queued = self.pendingTransition
                    self.pendingTransition = nil

                    if let queued,
                       queued.state.isOneShot,
                       self.isPendingOneShotStillRelevant(queued)
                    {
                        self.applyTransition(to: queued.state, svg: queued.svg, triggeringSession: queued.triggeringSession)
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

        if shouldSoftDelayIdleTransition(to: effectiveState, svg: nextSvg) {
            scheduleSoftIdleTransition(
                to: effectiveState,
                svg: nextSvg,
                triggeringSession: triggeringSession
            )
            return
        }

        applyTransition(to: effectiveState, svg: nextSvg, triggeringSession: triggeringSession)
    }

    private func shouldSoftDelayIdleTransition(to state: PetState, svg: String) -> Bool {
        !currentState.isSleepSequence &&
            state == .idle &&
            svg == Self.stateSVGs[.idle] &&
            currentSvg != svg
    }

    private func scheduleSoftIdleTransition(to state: PetState, svg: String, triggeringSession: Session?) {
        softIdleTimer?.invalidate()
        softIdleTransition = PendingTransition(state: state, svg: svg, triggeringSession: triggeringSession)

        let timer = Timer.scheduledTimer(withTimeInterval: Self.softIdleReturnDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                self.softIdleTimer = nil
                let queued = self.softIdleTransition
                self.softIdleTransition = nil

                guard let queued else {
                    return
                }

                self.applyTransition(
                    to: queued.state,
                    svg: queued.svg,
                    triggeringSession: queued.triggeringSession
                )
            }
        }

        softIdleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelSoftIdleTransition() {
        softIdleTimer?.invalidate()
        softIdleTimer = nil
        softIdleTransition = nil
    }

    private func isPendingOneShotStillRelevant(_ pending: PendingTransition) -> Bool {
        guard let triggeringSession = pending.triggeringSession else {
            return true
        }

        guard let currentSession = sessions[triggeringSession.id] else {
            return false
        }

        return currentSession.updatedAt == triggeringSession.updatedAt
    }

    /// 真正把状态/SVG/sourcePid 推送给 PetView 的最终落地点。
    /// 同时更新 `oneShotSourcePid`、`autoReturnTimer`、声效等所有副作用。
    private func applyTransition(to state: PetState, svg: String, triggeringSession: Session? = nil) {
        currentState = state
        currentSvg = svg
        stateChangedAt = Date()

        if state.isOneShot {
            oneShotSourcePid = triggeringSession?.sourcePid
            if let triggeringSession {
                oneShotFocusTarget = triggeringSession.focusTarget
            } else {
                oneShotFocusTarget = nil
            }
        } else {
            oneShotSourcePid = nil
            oneShotFocusTarget = nil
        }

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
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                self.autoReturnTimer = nil
                self.oneShotSourcePid = nil
                self.oneShotFocusTarget = nil
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
        case .collapsing:
            return doNotDisturbEnabled ? Self.stateSVGs[.collapsing] : "clawd-idle-collapse.svg"
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
