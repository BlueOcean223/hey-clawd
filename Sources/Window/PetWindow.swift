import AppKit

// 承载桌宠内容的透明浮窗，本身不负责动画逻辑。
final class PetWindow: NSWindow {
    private static let dragThreshold: CGFloat = 3
    private static let clickWindow: TimeInterval = 0.4
    private static let pokeReactionDuration: TimeInterval = 2.5
    private static let annoyedReactionDuration: TimeInterval = 3.5
    private static let doubleReactionDuration: TimeInterval = 3.5

    enum SizePreset {
        case small
        case medium
        case large

        var dimension: CGFloat {
            switch self {
            case .small:
                return 200
            case .medium:
                return 280
            case .large:
                return 360
            }
        }
    }

    private let petWebView: PetWebView
    private var dragStartPoint: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDraggingPet = false
    /// 反应动画播放期间，状态机更新只缓存，不直接覆盖当前 SVG。
    private var isShowingReaction = false
    private var currentDisplaySVGFilename = "clawd-idle-follow.svg"
    private var currentSourcePid: pid_t?
    private var clickCount = 0
    private var clickWindowTimer: Timer?
    private var reactionTimer: Timer?
    private var lastClickPoint: NSPoint?

    init(sizePreset: SizePreset = .small) {
        let size = NSSize(width: sizePreset.dimension, height: sizePreset.dimension)
        petWebView = PetWebView(frame: NSRect(origin: .zero, size: size))

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
        contentView = petWebView
        setFrame(originRect(for: size), display: false)
        // 先接默认 idle SVG，后续状态机会改这里。
        petWebView.loadSVG("clawd-idle-follow.svg")
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

    override func mouseDown(with event: NSEvent) {
        guard petWebView.shouldHandleMouse(at: event.locationInWindow) else {
            super.mouseDown(with: event)
            return
        }

        dragStartPoint = event.locationInWindow
        dragStartOrigin = frame.origin
        isDraggingPet = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let dragStartPoint,
            let dragStartOrigin
        else {
            super.mouseDragged(with: event)
            return
        }

        let deltaX = event.locationInWindow.x - dragStartPoint.x
        let deltaY = event.locationInWindow.y - dragStartPoint.y

        // 小抖动不算拖拽，留给后面的点击反应继续用。
        if !isDraggingPet, hypot(deltaX, deltaY) > Self.dragThreshold {
            isDraggingPet = true
            beginDragReactionIfNeeded()
        }

        guard isDraggingPet else {
            return
        }

        setFrameOrigin(NSPoint(
            x: dragStartOrigin.x + deltaX,
            y: dragStartOrigin.y + deltaY
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingPet {
            endDragReactionIfNeeded()
        } else if dragStartPoint != nil {
            handlePetClick(event)
        } else {
            super.mouseUp(with: event)
        }

        dragStartPoint = nil
        dragStartOrigin = nil
        isDraggingPet = false
    }

    /// 状态机已经选好了最终展示的 SVG，这里只负责把结果推给 WebView。
    func display(state _: PetState, svgFilename: String, sourcePid: pid_t?) {
        currentDisplaySVGFilename = svgFilename
        currentSourcePid = sourcePid

        guard !isShowingReaction else {
            return
        }

        petWebView.switchSVG(svgFilename)
    }

    private func beginDragReactionIfNeeded() {
        cancelClickWindow()
        reactionTimer?.invalidate()
        reactionTimer = nil
        isShowingReaction = true
        petWebView.playDragReaction()
    }

    private func endDragReactionIfNeeded() {
        guard isShowingReaction else {
            return
        }

        isShowingReaction = false
        // 拖拽期间状态机可能已经推进到新状态，恢复时以最新缓存结果为准。
        petWebView.resumeFromReaction(svgFilename: currentDisplaySVGFilename)
    }

    private func handlePetClick(_ event: NSEvent) {
        focusCurrentTerminal()
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

    private var canPlayClickReaction: Bool {
        !isShowingReaction && currentDisplaySVGFilename == "clawd-idle-follow.svg"
    }

    private func startClickWindow() {
        clickWindowTimer?.invalidate()
        clickWindowTimer = Timer.scheduledTimer(withTimeInterval: Self.clickWindow, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
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
            playTimedReaction(svgFilename: "clawd-react-annoyed.svg", duration: Self.annoyedReactionDuration)
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
        petWebView.playReaction(svgFilename: svgFilename)

        // 点击反应是一次性覆盖层，到时后始终回到状态机最新结果。
        reactionTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.reactionTimer = nil
                self.isShowingReaction = false
                self.petWebView.resumeFromReaction(svgFilename: self.currentDisplaySVGFilename)
            }
        }
        RunLoop.main.add(reactionTimer!, forMode: .common)
    }

    private func reactionSVGForClickPosition() -> String {
        let midX = contentView?.bounds.midX ?? frame.width / 2
        guard let lastClickPoint else {
            return "clawd-react-right.svg"
        }

        return lastClickPoint.x < midX ? "clawd-react-left.svg" : "clawd-react-right.svg"
    }

    private func focusCurrentTerminal() {
        guard let currentSourcePid, let app = NSRunningApplication(processIdentifier: currentSourcePid) else {
            return
        }

        app.activate(options: [.activateIgnoringOtherApps])
    }
}
