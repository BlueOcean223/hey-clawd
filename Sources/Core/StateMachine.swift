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
        StateMachine.oneShotStates.contains(self)
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

/// 复刻原版状态机的会话聚合逻辑。
/// 这里不直接关心网络和 UI，只负责根据会话集决定当前该显示哪个状态和 SVG。
final class StateMachine {
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
        "clawd-working-debugger.svg",
        "clawd-working-thinking.svg",
    ]

    private static let maxSessions = 20
    private static let staleCleanupInterval: TimeInterval = 10
    private static let sessionStaleInterval: TimeInterval = 600
    private static let workingStaleInterval: TimeInterval = 300

    private(set) var currentState: PetState = .idle
    private(set) var currentSvg: String = StateMachine.stateSVGs[.idle] ?? "clawd-idle-follow.svg"

    var onStateChange: ((PetState, String) -> Void)?

    private var sessions: [String: Session] = [:]
    private var stateChangedAt = Date()
    private var pendingTransition: PendingTransition?
    private var pendingTimer: Timer?
    private var autoReturnTimer: Timer?
    private var staleCleanupTimer: Timer?

    init() {
        startStaleCleanup()
    }

    func cleanup() {
        pendingTimer?.invalidate()
        autoReturnTimer?.invalidate()
        staleCleanupTimer?.invalidate()
        pendingTimer = nil
        autoReturnTimer = nil
        staleCleanupTimer = nil
        pendingTransition = nil
    }

    func setState(
        _ state: PetState,
        sessionId: String = "default",
        event: String? = nil,
        svg: String? = nil,
        svgWasProvided: Bool = false,
        sourcePid: pid_t? = nil,
        cwd: String? = nil,
        agentId: String? = nil,
        headless: Bool = false
    ) {
        let normalizedSessionId = sessionId.isEmpty ? "default" : sessionId
        let existing = sessions[normalizedSessionId]
        let nextSourcePid = sourcePid ?? existing?.sourcePid
        let nextCwd = normalizedString(cwd) ?? existing?.cwd
        let nextAgentId = normalizedString(agentId) ?? existing?.agentId
        let nextHeadless = headless || (existing?.headless ?? false)

        if sessions[normalizedSessionId] == nil, sessions.count >= Self.maxSessions {
            evictOldestSession()
        }

        if event == "PermissionRequest" {
            requestDisplayTransition(to: .notification, svgOverride: svgOverride(for: .notification))
            return
        }

        if event == "SessionEnd" {
            sessions.removeValue(forKey: normalizedSessionId)
            pruneStaleSessions(shouldTransition: false)

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
                agentId: nextAgentId,
                headless: nextHeadless
            )
        }

        pruneStaleSessions(shouldTransition: false)

        if state.isOneShot {
            requestDisplayTransition(to: state, svgOverride: svgOverride(for: state))
            return
        }

        let displayState = resolveDisplayState()
        requestDisplayTransition(to: displayState, svgOverride: svgOverride(for: displayState))
    }

    private func startStaleCleanup() {
        staleCleanupTimer?.invalidate()
        staleCleanupTimer = Timer.scheduledTimer(withTimeInterval: Self.staleCleanupInterval, repeats: true) { [weak self] _ in
            self?.pruneStaleSessions(shouldTransition: true)
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

    private func isSubagentStop(_ event: String?) -> Bool {
        event == "SubagentStop" || event == "subagentStop"
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
                updated.updatedAt = now
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
        let visibleSessions = sessions.values.filter { !$0.headless }
        guard !visibleSessions.isEmpty else {
            return .idle
        }

        return visibleSessions.max { lhs, rhs in
            if lhs.state.priority == rhs.state.priority {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.state.priority < rhs.state.priority
        }?.state ?? .idle
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

        let minDisplay = Self.minDisplayMs[currentState] ?? 0
        let elapsed = Date().timeIntervalSince(stateChangedAt)
        let remaining = (Double(minDisplay) / 1000.0) - elapsed

        if remaining > 0 {
            // 当前动画还在最小展示窗口内时，只保留最后一个更高优先级请求。
            pendingTimer?.invalidate()
            pendingTransition = PendingTransition(state: state, svg: nextSvg)
            autoReturnTimer?.invalidate()
            autoReturnTimer = nil

            let timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
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
        onStateChange?(state, svg)

        autoReturnTimer?.invalidate()
        autoReturnTimer = nil

        guard let autoReturnMs = Self.autoReturnMs[state] else {
            return
        }

        // 一次性状态展示结束后，不记住它本身，而是回到当前会话集合算出来的结果。
        let timer = Timer.scheduledTimer(withTimeInterval: Double(autoReturnMs) / 1000.0, repeats: false) { [weak self] _ in
            guard let self else {
                return
            }

            self.autoReturnTimer = nil
            let resolvedState = self.resolveDisplayState()
            self.requestDisplayTransition(to: resolvedState, svgOverride: self.svgOverride(for: resolvedState))
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

            if session.state == .working || session.state == .thinking || session.state == .juggling {
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
