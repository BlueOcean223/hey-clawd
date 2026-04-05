import AppKit

// 承载桌宠内容的透明浮窗，本身不负责动画逻辑。
final class PetWindow: NSWindow {
    private static let dragThreshold: CGFloat = 3

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
    private var isShowingDragReaction = false
    private var currentDisplaySVGFilename = "clawd-idle-follow.svg"

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
        } else {
            super.mouseUp(with: event)
        }

        dragStartPoint = nil
        dragStartOrigin = nil
        isDraggingPet = false
    }

    /// 状态机已经选好了最终展示的 SVG，这里只负责把结果推给 WebView。
    func display(state _: PetState, svgFilename: String) {
        currentDisplaySVGFilename = svgFilename

        guard !isShowingDragReaction else {
            return
        }

        petWebView.switchSVG(svgFilename)
    }

    private func beginDragReactionIfNeeded() {
        guard !isShowingDragReaction else {
            return
        }

        isShowingDragReaction = true
        petWebView.playDragReaction()
    }

    private func endDragReactionIfNeeded() {
        guard isShowingDragReaction else {
            return
        }

        isShowingDragReaction = false
        // 拖拽期间状态机可能已经推进到新状态，恢复时以最新缓存结果为准。
        petWebView.resumeFromReaction(svgFilename: currentDisplaySVGFilename)
    }
}
