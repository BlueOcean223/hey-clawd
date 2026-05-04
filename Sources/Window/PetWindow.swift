@preconcurrency import AppKit
import QuartzCore

// 承载桌宠内容的透明浮窗，本身不负责动画逻辑。
//
// 角色拆分：本类管事件路由（点击/拖拽/右键菜单）、屏幕约束、occlusion 暂停、
// 以及"反应动画"短期覆盖层（被点 / 被拖时插播一段 SVG，结束后回到状态机最新结果）。
// 真正的渲染由 PetView 完成，状态机决策由 AppDelegate 注入 `display(state:svgFilename:sourcePid:)`。
@MainActor final class PetWindow: NSWindow {
    /// 拖拽超过这个距离才认为是真的"在拖"，避免单次点击被误判成短拖。
    private static let dragThreshold: CGFloat = 3
    /// 多击窗口期：在窗内累积的点击数会触发不同等级的反应动画。
    private static let clickWindow: TimeInterval = 0.4
    private static let pokeReactionDuration: TimeInterval = 2.5
    private static let annoyedReactionDuration: TimeInterval = 3.5
    private static let doubleReactionDuration: TimeInterval = 3.5
    /// 100% 时的窗口尺寸；其它百分比由 `applySizePercent` 等比缩放。
    private static let baseDimension: CGFloat = 200

    private let petView: PetView
    private var dragStartPoint: NSPoint?
    private var dragStartScreenPoint: NSPoint?
    private var dragCursorOffsetFromOrigin: NSPoint?
    private var isDraggingPet = false
    /// 反应动画播放期间，状态机更新只缓存，不直接覆盖当前 SVG。
    private var isShowingReaction = false
    private var currentDisplaySVGFilename = "clawd-idle-follow.svg"
    private var currentSourcePid: pid_t?
    private var clickCount = 0
    private var clickWindowTimer: Timer?
    private var reactionTimer: Timer?
    private var lastClickPoint: NSPoint?
    private var isPausedForOcclusion = false
    private(set) var sizePercent: Int
    var allowsDragging = true
    /// mini 模式需要允许窗口半藏在屏幕外；普通模式则始终钳回工作区。
    var allowsPartialOffscreenPlacement = false
    var contextMenuProvider: (() -> NSMenu?)?
    /// 只在拖拽落点确定后回调，避免把中间过程频繁写进 UserDefaults。
    var onDragEnded: ((NSPoint) -> Void)?
    /// mini 模式会在这里接管拖拽中的位置约束，比如贴边移动或拖拽脱离。
    var onDragMove: ((NSPoint) -> NSPoint)?
    /// 上层可以在拖拽期间暂停无关轮询，减轻窗口跟手时的主线程压力。
    var onDragStateChange: ((Bool) -> Void)?
    /// 聚焦逻辑交给上层协调，这里只负责把点击事件抛出去。
    var onPetClick: (() -> Void)?

    init(sizePercent: Int = 100) {
        self.sizePercent = sizePercent
        let dim = Self.baseDimension * CGFloat(sizePercent) / 100
        let size = NSSize(width: dim, height: dim)
        petView = PetView(frame: NSRect(origin: .zero, size: size))

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        // 命中采样跟着鼠标走，需要持续收到 mouse moved。
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        // 所有桌面可见，并且切换 Space 时不参与系统重排。
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        contentView = petView
        setFrame(originRect(for: size), display: false)
        observeScreenChanges()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOcclusionStateChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: self
        )
        // 先接默认 idle SVG，后续状态机会改这里。
        petView.loadSVG("clawd-idle-follow.svg")
    }

    // 禁用系统默认的窗口位置约束，否则 macOS 会把无边框窗口的
    // 顶部限制在 visibleFrame 内，导致拖拽时无法接近屏幕上方。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func applySizePercent(_ percent: Int) {
        guard percent != sizePercent else {
            return
        }

        sizePercent = percent
        let dim = Self.baseDimension * CGFloat(percent) / 100
        let newSize = NSSize(width: dim, height: dim)
        let nextFrame = NSRect(origin: frame.origin, size: newSize)
        setFrame(nextFrame, display: true, animate: false)
        clampToScreen()
    }

    func clampToScreen() {
        guard !allowsPartialOffscreenPlacement else {
            return
        }

        let center = NSPoint(x: frame.midX, y: frame.midY)
        let workArea = nearestWorkArea(for: center)
        var clampedOrigin = frame.origin
        clampedOrigin.x = max(workArea.minX, min(clampedOrigin.x, workArea.maxX - frame.width))
        // 拖拽过程中不做系统级约束，但最终落点还是要留在可视工作区内。
        clampedOrigin.y = max(workArea.minY, min(clampedOrigin.y, workArea.maxY - frame.height))

        guard clampedOrigin != frame.origin else {
            return
        }

        setFrameOrigin(clampedOrigin)
    }

    private func originRect(for size: NSSize) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - 100,
            y: visibleFrame.minY + 50
        )

        return NSRect(origin: origin, size: size)
    }

    private func observeScreenChanges() {
        // 外接显示器插拔会改变 visibleFrame；窗口自己要把位置压回最近工作区。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChanged(_ notification: Notification) {
        _ = notification
        clampToScreen()
    }

    @objc private func handleOcclusionStateChanged(_ notification: Notification) {
        _ = notification
        if occlusionState.contains(.visible) {
            resumeFromOcclusion()
        } else {
            pauseForOcclusion()
        }
    }

    /// 暂停 SVG 动画与眼球跟踪。借助 layer.speed/timeOffset 冻结 Core Animation 时间，
    /// 解除时再用 beginTime 把"暂停的时长"补回去，保证恢复后动画曲线连续。
    private func pauseForOcclusion() {
        guard !isPausedForOcclusion else {
            return
        }

        isPausedForOcclusion = true
        guard let rootLayer = petView.layer else {
            return
        }

        let pausedTime = rootLayer.convertTime(CACurrentMediaTime(), from: nil)
        rootLayer.speed = 0
        rootLayer.timeOffset = pausedTime
        if !isShowingReaction {
            petView.pauseTracking()
        }
    }

    private func resumeFromOcclusion() {
        guard isPausedForOcclusion else {
            return
        }

        isPausedForOcclusion = false
        guard let rootLayer = petView.layer else {
            return
        }

        let pausedTime = rootLayer.timeOffset
        rootLayer.speed = 1
        rootLayer.timeOffset = 0
        rootLayer.beginTime = 0
        let timeSincePause = rootLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        rootLayer.beginTime = timeSincePause
        if !isShowingReaction {
            petView.resumeTracking()
        }
    }

    private func nearestWorkArea(for origin: NSPoint) -> NSRect {
        let screens = NSScreen.screens
        guard let nearestScreen = screens.min(by: { lhs, rhs in
            distanceToWorkArea(origin, lhs.visibleFrame) < distanceToWorkArea(origin, rhs.visibleFrame)
        }) else {
            return NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: frame.size)
        }

        return nearestScreen.visibleFrame
    }

    private func distanceToWorkArea(_ point: NSPoint, _ workArea: NSRect) -> CGFloat {
        let dx: CGFloat
        if point.x < workArea.minX {
            dx = workArea.minX - point.x
        } else if point.x > workArea.maxX {
            dx = point.x - workArea.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < workArea.minY {
            dy = workArea.minY - point.y
        } else if point.y > workArea.maxY {
            dy = point.y - workArea.maxY
        } else {
            dy = 0
        }

        return hypot(dx, dy)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if petView.shouldHandleMouse(at: event.locationInWindow) {
                handleLeftMouseDown(event)
                return
            }
        case .leftMouseDragged:
            if dragStartPoint != nil {
                handleLeftMouseDragged(event)
                return
            }
        case .leftMouseUp:
            if dragStartPoint != nil || isDraggingPet {
                handleLeftMouseUp(event)
                return
            }
        case .rightMouseDown:
            if petView.shouldHandleMouse(at: event.locationInWindow) {
                handleRightMouseDown(event)
                return
            }
        default:
            break
        }

        super.sendEvent(event)
    }

    func setMiniLeft(_ enabled: Bool) {
        petView.setMiniLeft(enabled)
    }

    /// 状态机已经选好了最终展示的 SVG，这里只负责把结果推给 PetView。
    func display(state _: PetState, svgFilename: String, sourcePid: pid_t?) {
        currentDisplaySVGFilename = svgFilename
        currentSourcePid = sourcePid

        guard !isShowingReaction else {
            return
        }

        petView.switchSVG(svgFilename)
    }

    /// 开始播放拖拽反应动画，并把状态机推送过来的更新先缓冲（不直接换 SVG）。
    /// 拖拽结束后再用最新缓冲值恢复展示。
    private func beginDragReactionIfNeeded() {
        cancelClickWindow()
        reactionTimer?.invalidate()
        reactionTimer = nil
        isShowingReaction = true
        onDragStateChange?(true)
        petView.pauseTracking()
        petView.playDragReaction()
    }

    private func endDragReactionIfNeeded() {
        guard isShowingReaction else {
            return
        }

        isShowingReaction = false
        onDragStateChange?(false)
        petView.resumeTracking()
        // 拖拽期间状态机可能已经推进到新状态，恢复时以最新缓存结果为准。
        petView.resumeFromReaction(svgFilename: currentDisplaySVGFilename)
    }

    private func handleLeftMouseDown(_ event: NSEvent) {
        dragStartPoint = event.locationInWindow
        let screenPoint = NSEvent.mouseLocation
        dragStartScreenPoint = screenPoint
        dragCursorOffsetFromOrigin = NSPoint(
            x: screenPoint.x - frame.origin.x,
            y: screenPoint.y - frame.origin.y
        )
        isDraggingPet = false
    }

    private func handleLeftMouseDragged(_ event: NSEvent) {
        guard allowsDragging else {
            return
        }

        guard
            let dragStartScreenPoint,
            let dragCursorOffsetFromOrigin
        else {
            return
        }

        let screenPoint = NSEvent.mouseLocation

        // 用屏幕坐标判断拖拽阈值。窗口自己在移动时，locationInWindow 不再可靠。
        if !isDraggingPet {
            let distance = hypot(
                screenPoint.x - dragStartScreenPoint.x,
                screenPoint.y - dragStartScreenPoint.y
            )
            if distance > Self.dragThreshold {
                isDraggingPet = true
                beginDragReactionIfNeeded()
            }
        }

        guard isDraggingPet else {
            return
        }

        let proposedOrigin = NSPoint(
            x: screenPoint.x - dragCursorOffsetFromOrigin.x,
            y: screenPoint.y - dragCursorOffsetFromOrigin.y
        )
        let resolvedOrigin = onDragMove?(proposedOrigin) ?? proposedOrigin
        setFrameOrigin(resolvedOrigin)
    }

    private func handleLeftMouseUp(_ event: NSEvent) {
        if isDraggingPet {
            endDragReactionIfNeeded()
            onDragEnded?(frame.origin)
        } else if dragStartPoint != nil {
            handlePetClick(event)
        }

        dragStartPoint = nil
        dragStartScreenPoint = nil
        dragCursorOffsetFromOrigin = nil
        isDraggingPet = false
    }

    private func handleRightMouseDown(_ event: NSEvent) {
        cancelClickWindow()
        guard let menu = contextMenuProvider?() else {
            return
        }

        NSMenu.popUpContextMenu(menu, with: event, for: contentView ?? petView)
    }

    /// 多击触发不同档位反应：
    /// - 单击：focus 终端；
    /// - 2-3 击：随机 poke / annoyed / dizzy；
    /// - ≥4 击：直接进 double-jump，不等窗口结束。
    private func handlePetClick(_ event: NSEvent) {
        onPetClick?()
        lastClickPoint = event.locationInWindow

        guard canPlayClickReaction else {
            cancelClickWindow()
            return
        }

        clickCount += 1
        if clickCount == 1 {
            startClickWindow()
            return
        }

        // 四连击是更高优先级分支，命中后立刻触发，不等窗口结束。
        if clickCount >= 4 {
            cancelClickWindow()
            playTimedReaction(
                svgFilename: Bool.random() ? "clawd-react-double.svg" : "clawd-react-double-jump.svg",
                duration: Self.doubleReactionDuration
            )
        }
    }

    /// 反应只在桌宠处于 idle-follow 时播；状态机正在驱动其它动画时不打断。
    private var canPlayClickReaction: Bool {
        !isShowingReaction && currentDisplaySVGFilename == "clawd-idle-follow.svg"
    }

    private func startClickWindow() {
        clickWindowTimer?.invalidate()
        clickWindowTimer = Timer.scheduledTimer(withTimeInterval: Self.clickWindow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishClickWindow()
            }
        }
        RunLoop.main.add(clickWindowTimer!, forMode: .common)
    }

    private func finishClickWindow() {
        let finalClickCount = clickCount
        cancelClickWindow()

        guard finalClickCount >= 2, canPlayClickReaction else {
            return
        }

        if Bool.random() {
            let reaction = reactionSVGForClickPosition()
            playTimedReaction(svgFilename: reaction, duration: Self.pokeReactionDuration)
        } else {
            let annoyed = Bool.random() ? "clawd-react-annoyed.svg" : "clawd-dizzy.svg"
            playTimedReaction(svgFilename: annoyed, duration: Self.annoyedReactionDuration)
        }
    }

    private func cancelClickWindow() {
        clickWindowTimer?.invalidate()
        clickWindowTimer = nil
        clickCount = 0
    }

    private func playTimedReaction(svgFilename: String, duration: TimeInterval) {
        reactionTimer?.invalidate()
        isShowingReaction = true
        petView.playReaction(svgFilename: svgFilename)

        // 点击反应是一次性覆盖层，到时后始终回到状态机最新结果。
        reactionTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                self.reactionTimer = nil
                self.isShowingReaction = false
                self.petView.resumeFromReaction(svgFilename: self.currentDisplaySVGFilename)
            }
        }
        RunLoop.main.add(reactionTimer!, forMode: .common)
    }

    private func reactionSVGForClickPosition() -> String {
        let midX = contentView?.bounds.midX ?? frame.width / 2
        guard let lastClickPoint else {
            return "clawd-react-right.svg"
        }

        // 偶尔敬礼替代方向反应
        if Int.random(in: 0..<5) == 0 {
            return "clawd-react-salute.svg"
        }

        return lastClickPoint.x < midX ? "clawd-react-left.svg" : "clawd-react-right.svg"
    }
}
