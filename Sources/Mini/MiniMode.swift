import AppKit
import Foundation

@MainActor
final class MiniMode {
    private enum Edge: String {
        case left
        case right
    }

    static let miniOffsetRatio: CGFloat = 0.486
    static let peekOffset: CGFloat = 25
    static let snapTolerance: CGFloat = 30
    static let jumpPeakHeight: CGFloat = 40
    static let jumpDuration: TimeInterval = 0.35
    static let crabwalkSpeed: CGFloat = 0.12
    private static let dragDetachThreshold: CGFloat = 45
    private static let dragReturnDuration: TimeInterval = 0.12
    private static let revealDeadZone: CGFloat = 8
    private static let jitterThreshold: CGFloat = 1
    private static let enterHoldDuration: TimeInterval = 3.2
    private static let animationFrameInterval: TimeInterval = 0.016
    private static let hoverPollInterval: TimeInterval = 0.12

    private unowned let petWindow: PetWindow
    private unowned let stateMachine: StateMachine
    private let preferences: Preferences

    var onNeedsBubbleReposition: (() -> Void)?
    var onNeedsMenuRefresh: (() -> Void)?
    var onDidWakeFromDND: (() -> Void)?

    private var edge: Edge = .right
    private var preMiniOrigin: NSPoint = .zero
    private var currentMiniX: CGFloat = 0
    private var miniSnap: CGRect?
    private var animationTimer: Timer?
    private var animationCompletion: (() -> Void)?
    private var transitionTimer: Timer?
    private var hoverTimer: Timer?
    private var isAnimating = false
    private var isHoveringPet = false
    private var miniSleepPeeked = false
    private var dragDetachProgress: CGFloat = 0

    init(petWindow: PetWindow, stateMachine: StateMachine, preferences: Preferences = .shared) {
        self.petWindow = petWindow
        self.stateMachine = stateMachine
        self.preferences = preferences
    }

    var isEnabled: Bool {
        stateMachine.miniModeEnabled
    }

    var isTransitioning: Bool {
        stateMachine.miniTransitioning
    }

    func restoreFromPreferencesIfNeeded() {
        guard preferences.miniModeEnabled else {
            return
        }

        edge = Edge(rawValue: preferences.miniEdge) ?? .right
        preMiniOrigin = preferences.preMiniOrigin ?? petWindow.frame.origin

        let size = petWindow.frame.size
        let savedOrigin = preferences.windowOrigin ?? petWindow.frame.origin
        let workArea = nearestWorkArea(for: pointAtCenter(of: CGRect(origin: savedOrigin, size: size)))
        let clampedY = clampY(savedOrigin.y, in: workArea, height: size.height)
        currentMiniX = miniX(in: workArea, size: size, edge: edge)
        miniSnap = CGRect(x: currentMiniX, y: clampedY, width: size.width, height: size.height)

        petWindow.allowsDragging = true
        petWindow.setMiniLeft(edge == .left)
        petWindow.setFrameOrigin(NSPoint(x: currentMiniX, y: clampedY))

        stateMachine.setMiniModeEnabled(true)
        stateMachine.setMiniTransitioning(false)
        stateMachine.setMiniPeekEnabled(false)
        stateMachine.requestMiniDisplayState(preferences.doNotDisturbEnabled ? .miniSleep : .miniIdle)

        preferences.windowOrigin = petWindow.frame.origin
        startHoverMonitoring()
        onNeedsMenuRefresh?()
    }

    @discardableResult
    func handleDragEnded() -> Bool {
        guard !isTransitioning else {
            dragDetachProgress = 0
            return true
        }

        if isEnabled {
            if dragDetachProgress > 0 {
                // 没拖到脱离阈值时，松手后顺滑回边，避免“卡住一下再跳回去”。
                animateWindowX(to: currentMiniX, duration: Self.dragReturnDuration)
            } else {
                preferences.windowOrigin = petWindow.frame.origin
            }
            dragDetachProgress = 0
            return true
        }

        dragDetachProgress = 0

        let size = petWindow.frame.size
        let frame = petWindow.frame
        let center = pointAtCenter(of: frame)
        // 桌宠半藏在屏幕外时 center 可能不在任何 visibleFrame 内，
        // 用 nearestWorkArea 保证总能找到最近的屏幕做 snap 判定。
        let workArea = nearestWorkArea(for: center)

        let margin = round(size.width * 0.25)
        let rightLimit = workArea.maxX - size.width + margin
        if frame.minX >= rightLimit - Self.snapTolerance {
            enterFromDrag(in: workArea, edge: .right)
            return true
        }

        let leftLimit = workArea.minX - margin
        if frame.minX <= leftLimit + Self.snapTolerance {
            enterFromDrag(in: workArea, edge: .left)
            return true
        }

        return false
    }

    func handleDragMove(proposedOrigin: NSPoint) -> NSPoint {
        guard isEnabled, !isTransitioning else {
            return proposedOrigin
        }

        let size = petWindow.frame.size
        let currentOrigin = petWindow.frame.origin
        if shouldDetachFromMini(currentOrigin: currentOrigin, proposedOrigin: proposedOrigin) {
            detachFromMiniForDrag(at: proposedOrigin)
            return proposedOrigin
        }

        let workArea = nearestWorkArea(for: pointAtCenter(of: CGRect(origin: proposedOrigin, size: size)))
        currentMiniX = miniX(in: workArea, size: size, edge: edge)
        let clampedY = clampY(proposedOrigin.y, in: workArea, height: size.height)
        miniSnap = CGRect(x: currentMiniX, y: clampedY, width: size.width, height: size.height)

        // 没完全脱离前允许一点横向”拉伸”，视觉上像从边缘被拽出来，而不是锁死后突然弹出。
        // revealDeadZone 以内不做任何横移，滤掉纯纵向拖拽时的鼠标抖动。
        let effectiveProgress = max(0, dragDetachProgress - Self.revealDeadZone)
        let effectiveRange = Self.dragDetachThreshold - Self.revealDeadZone
        let revealProgress = min(1, effectiveProgress / effectiveRange)
        let easedReveal = revealProgress * (2 - revealProgress)
        let revealDistance = effectiveRange * easedReveal
        let displayX: CGFloat
        switch edge {
        case .left:
            displayX = currentMiniX + revealDistance
        case .right:
            displayX = currentMiniX - revealDistance
        }

        let displayOrigin = NSPoint(x: displayX, y: clampedY)
        preferences.windowOrigin = NSPoint(x: currentMiniX, y: clampedY)
        return displayOrigin
    }

    func enterViaMenu() {
        guard !isEnabled, !isTransitioning else {
            return
        }

        let frame = petWindow.frame
        let size = frame.size
        let workArea = nearestWorkArea(for: pointAtCenter(of: frame))
        let edge: Edge = frame.midX <= workArea.midX ? .left : .right
        let edgeX: CGFloat
        if edge == .right {
            edgeX = workArea.maxX - size.width + round(size.width * 0.25)
        } else {
            edgeX = workArea.minX - round(size.width * 0.25)
        }

        prepareMiniMode(edge: edge, preMiniOrigin: frame.origin)
        stateMachine.requestMiniDisplayState(.miniCrabwalk)

        let walkDistance = abs(frame.minX - edgeX)
        let walkDuration = max(0.1, TimeInterval(walkDistance / Self.crabwalkSpeed) / 1000.0)
        animateWindowX(to: edgeX, duration: walkDuration)

        scheduleTransition(after: walkDuration + 0.05) { [weak self] in
            self?.finishMenuEntry(in: workArea)
        }
    }

    func exit() {
        guard isEnabled else {
            return
        }

        cancelTransitionTimers()
        stopHoverMonitoring()

        // 退出抛物线期间仍保留 miniMode=true，这样普通状态和布局更新都不会打断动画。
        petWindow.setMiniLeft(false)
        stateMachine.setMiniTransitioning(true)
        stateMachine.setMiniPeekEnabled(false)
        isHoveringPet = false
        miniSleepPeeked = false
        miniSnap = nil

        let size = petWindow.frame.size
        var clamped = clampToVisibleArea(origin: preMiniOrigin, size: size)
        let workArea = nearestWorkArea(for: pointAtCenter(of: CGRect(origin: clamped, size: size)))
        let margin = round(size.width * 0.25)

        if clamped.x >= workArea.maxX - size.width + margin - Self.snapTolerance {
            clamped.x = workArea.maxX - size.width + margin - 100
        }
        if clamped.x <= workArea.minX - margin + Self.snapTolerance {
            clamped.x = workArea.minX - margin + Self.snapTolerance + 100
        }

        animateWindowParabola(to: clamped, duration: Self.jumpDuration) { [weak self] in
            guard let self else {
                return
            }

            self.petWindow.allowsDragging = true
            self.stateMachine.setMiniModeEnabled(false)
            self.stateMachine.setMiniTransitioning(false)
            self.preferences.miniModeEnabled = false
            self.preferences.windowOrigin = clamped
            self.onNeedsMenuRefresh?()

            if self.preferences.doNotDisturbEnabled {
                self.onDidWakeFromDND?()
            } else {
                self.stateMachine.refreshDisplayState()
            }
        }
    }

    func handleSizeChange() {
        guard isEnabled else {
            return
        }

        let size = petWindow.frame.size
        let snapY = miniSnap?.minY ?? petWindow.frame.minY
        let workArea = nearestWorkArea(for: NSPoint(x: currentMiniX + size.width / 2, y: snapY + size.height / 2))
        currentMiniX = miniX(in: workArea, size: size, edge: edge)
        let clampedY = clampY(snapY, in: workArea, height: size.height)
        miniSnap = CGRect(x: currentMiniX, y: clampedY, width: size.width, height: size.height)
        petWindow.setFrameOrigin(NSPoint(x: currentMiniX, y: clampedY))
        preferences.windowOrigin = petWindow.frame.origin
    }

    func cleanup() {
        cancelTransitionTimers()
        stopHoverMonitoring()
    }

    private func enterFromDrag(in workArea: CGRect, edge: Edge) {
        let origin = petWindow.frame.origin
        prepareMiniMode(edge: edge, preMiniOrigin: origin)
        finishEntry(in: workArea, animatedFromMenu: false)
    }

    private func finishMenuEntry(in workArea: CGRect) {
        let size = petWindow.frame.size
        let jumpTargetX: CGFloat
        if edge == .right {
            let farthestRight = NSScreen.screens.map(\.frame.maxX).max() ?? workArea.maxX
            jumpTargetX = farthestRight
        } else {
            let farthestLeft = NSScreen.screens.map(\.frame.minX).min() ?? workArea.minX
            jumpTargetX = farthestLeft - size.width
        }

        animateWindowParabola(
            to: NSPoint(x: jumpTargetX, y: petWindow.frame.minY),
            duration: Self.jumpDuration
        ) { [weak self] in
            self?.finishEntry(in: workArea, animatedFromMenu: true)
        }
    }

    private func finishEntry(in workArea: CGRect, animatedFromMenu: Bool) {
        let size = petWindow.frame.size
        currentMiniX = miniX(in: workArea, size: size, edge: edge)
        let clampedY = clampY(petWindow.frame.minY, in: workArea, height: size.height)
        miniSnap = CGRect(x: currentMiniX, y: clampedY, width: size.width, height: size.height)

        let enterState: PetState = preferences.doNotDisturbEnabled ? .miniEnterSleep : .miniEnter

        if animatedFromMenu {
            petWindow.setFrameOrigin(NSPoint(x: currentMiniX, y: clampedY))
            stateMachine.requestMiniDisplayState(enterState)
        } else {
            animateWindowX(to: currentMiniX, duration: 0.1)
            stateMachine.requestMiniDisplayState(enterState)
        }

        preferences.windowOrigin = NSPoint(x: currentMiniX, y: clampedY)
        scheduleTransition(after: Self.enterHoldDuration) { [weak self] in
            guard let self else {
                return
            }

            self.stateMachine.setMiniTransitioning(false)
            self.stateMachine.requestMiniDisplayState(
                self.preferences.doNotDisturbEnabled ? .miniSleep : .miniIdle
            )
            self.petWindow.allowsDragging = true
            self.startHoverMonitoring()
            self.onNeedsMenuRefresh?()
        }
    }

    private func prepareMiniMode(edge: Edge, preMiniOrigin: NSPoint) {
        self.edge = edge
        self.preMiniOrigin = preMiniOrigin
        isHoveringPet = false
        miniSleepPeeked = false
        dragDetachProgress = 0

        petWindow.setMiniLeft(edge == .left)
        petWindow.allowsDragging = false
        stateMachine.setMiniModeEnabled(true)
        stateMachine.setMiniTransitioning(true)
        stateMachine.setMiniPeekEnabled(false)

        preferences.miniModeEnabled = true
        preferences.miniEdge = edge.rawValue
        preferences.preMiniOrigin = preMiniOrigin

        stopHoverMonitoring()
        onNeedsMenuRefresh?()
    }

    private func startHoverMonitoring() {
        stopHoverMonitoring()

        let timer = Timer.scheduledTimer(withTimeInterval: Self.hoverPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollHover()
            }
        }

        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHoverMonitoring() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        isHoveringPet = false
        miniSleepPeeked = false
    }

    private func pollHover() {
        guard isEnabled, !isTransitioning, !isAnimating else {
            return
        }

        let mouseOverPet = isMouseOverPet()
        guard mouseOverPet != isHoveringPet else {
            return
        }

        isHoveringPet = mouseOverPet

        if stateMachine.currentState == .miniSleep {
            if mouseOverPet {
                miniSleepPeeked = true
                animateWindowX(to: currentMiniX + peekOffset(for: edge), duration: 0.2)
            } else if miniSleepPeeked {
                miniSleepPeeked = false
                animateWindowX(to: currentMiniX, duration: 0.2)
            }
            return
        }

        // 先把 hover 事实记进状态机，mini-alert / mini-happy 回落时才能自然接到 mini-peek。
        stateMachine.setMiniPeekEnabled(mouseOverPet)

        guard stateMachine.currentState == .miniIdle || stateMachine.currentState == .miniPeek else {
            return
        }

        if mouseOverPet {
            animateWindowX(to: currentMiniX + peekOffset(for: edge), duration: 0.2)
        } else {
            animateWindowX(to: currentMiniX, duration: 0.2)
        }
    }

    private func animateWindowX(to targetX: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        cancelAnimationTimer()
        animationCompletion = completion

        let startFrame = petWindow.frame
        let startX = startFrame.minX
        if abs(startX - targetX) < 0.5 {
            isAnimating = false
            finishAnimation()
            return
        }

        isAnimating = true
        let startTime = Date()
        let duration = max(duration, Self.animationFrameInterval)
        let fixedY = miniSnap?.minY ?? startFrame.minY

        let timer = Timer.scheduledTimer(withTimeInterval: Self.animationFrameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(1, elapsed / duration)
                let eased = progress * (2 - progress)
                let nextX = round(startX + (targetX - startX) * eased)
                self.petWindow.setFrameOrigin(NSPoint(x: nextX, y: fixedY))
                self.preferences.windowOrigin = self.petWindow.frame.origin
                self.onNeedsBubbleReposition?()

                if progress >= 1 {
                    self.finishAnimation()
                }
            }
        }

        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func animateWindowParabola(to targetOrigin: NSPoint, duration: TimeInterval, completion: (() -> Void)? = nil) {
        cancelAnimationTimer()
        animationCompletion = completion

        let startOrigin = petWindow.frame.origin
        if hypot(targetOrigin.x - startOrigin.x, targetOrigin.y - startOrigin.y) < 0.5 {
            isAnimating = false
            finishAnimation()
            return
        }

        isAnimating = true
        let startTime = Date()
        let duration = max(duration, Self.animationFrameInterval)

        let timer = Timer.scheduledTimer(withTimeInterval: Self.animationFrameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(1, elapsed / duration)
                let eased = progress * (2 - progress)
                let nextX = round(startOrigin.x + (targetOrigin.x - startOrigin.x) * eased)
                let arc = -4 * Self.jumpPeakHeight * progress * (progress - 1)
                let nextY = round(startOrigin.y + (targetOrigin.y - startOrigin.y) * eased - arc)
                self.petWindow.setFrameOrigin(NSPoint(x: nextX, y: nextY))
                self.onNeedsBubbleReposition?()

                if progress >= 1 {
                    self.finishAnimation()
                }
            }
        }

        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleTransition(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        transitionTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }

        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelTransitionTimers() {
        transitionTimer?.invalidate()
        transitionTimer = nil
        cancelAnimationTimer()
    }

    private func cancelAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationCompletion = nil
        isAnimating = false
    }

    private func finishAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimating = false

        let completion = animationCompletion
        animationCompletion = nil
        completion?()
    }

    private func miniX(in workArea: CGRect, size: NSSize, edge: Edge) -> CGFloat {
        switch edge {
        case .left:
            return workArea.minX - round(size.width * Self.miniOffsetRatio)
        case .right:
            return workArea.maxX - round(size.width * (1 - Self.miniOffsetRatio))
        }
    }

    private func shouldDetachFromMini(currentOrigin: NSPoint, proposedOrigin: NSPoint) -> Bool {
        let inwardStep: CGFloat
        switch edge {
        case .left:
            inwardStep = proposedOrigin.x - currentOrigin.x
        case .right:
            inwardStep = currentOrigin.x - proposedOrigin.x
        }

        // 单帧横移 ≤ jitterThreshold 视为鼠标抖动，不参与累计，
        // 防止纵向拖拽时因 max(0,...) 棘轮效应缓慢漂移到脱离阈值。
        guard abs(inwardStep) > Self.jitterThreshold else {
            return false
        }

        if inwardStep > 0 {
            dragDetachProgress += inwardStep
        } else {
            dragDetachProgress = max(0, dragDetachProgress + inwardStep)
        }

        return dragDetachProgress > Self.dragDetachThreshold
    }

    private func detachFromMiniForDrag(at handoffOrigin: NSPoint) {
        cancelTransitionTimers()
        stopHoverMonitoring()
        miniSnap = nil
        miniSleepPeeked = false
        isHoveringPet = false
        dragDetachProgress = 0

        petWindow.setMiniLeft(false)
        petWindow.allowsDragging = true
        stateMachine.setMiniPeekEnabled(false)
        stateMachine.setMiniTransitioning(false)
        stateMachine.setMiniModeEnabled(false)
        preferences.miniModeEnabled = false
        preferences.windowOrigin = handoffOrigin
        onNeedsMenuRefresh?()
        stateMachine.refreshDisplayState()
    }

    private func peekOffset(for edge: Edge) -> CGFloat {
        edge == .left ? Self.peekOffset : -Self.peekOffset
    }

    private func nearestWorkArea(for point: NSPoint) -> CGRect {
        if let exact = NSScreen.screens.first(where: { $0.visibleFrame.contains(point) }) {
            return exact.visibleFrame
        }

        let sorted = NSScreen.screens.sorted { lhs, rhs in
            distanceSquared(from: point, to: lhs.visibleFrame.center) < distanceSquared(from: point, to: rhs.visibleFrame.center)
        }

        return sorted.first?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: petWindow.frame.size)
    }

    private func clampToVisibleArea(origin: NSPoint, size: NSSize) -> NSPoint {
        let workArea = nearestWorkArea(for: pointAtCenter(of: CGRect(origin: origin, size: size)))
        let maxX = max(workArea.minX, workArea.maxX - size.width)
        let maxY = max(workArea.minY, workArea.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, workArea.minX), maxX),
            y: min(max(origin.y, workArea.minY), maxY)
        )
    }

    private func clampY(_ y: CGFloat, in workArea: CGRect, height: CGFloat) -> CGFloat {
        let maxY = max(workArea.minY, workArea.maxY - height)
        return min(max(y, workArea.minY), maxY)
    }

    private func isMouseOverPet() -> Bool {
        let mouseLocation = NSEvent.mouseLocation
        guard petWindow.frame.contains(mouseLocation) else {
            return false
        }

        let localPoint = petWindow.convertPoint(fromScreen: mouseLocation)
        guard let petWebView = petWindow.contentView as? PetWebView else {
            return true
        }

        return petWebView.shouldHandleHover(at: localPoint)
    }

    private func pointAtCenter(of rect: CGRect) -> NSPoint {
        NSPoint(x: rect.midX, y: rect.midY)
    }

    private func distanceSquared(from lhs: NSPoint, to rhs: NSPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private extension CGRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
