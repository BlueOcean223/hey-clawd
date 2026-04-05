import AppKit

// 承载桌宠内容的透明浮窗，本身不负责动画逻辑。
final class PetWindow: NSWindow {
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

    override func sendEvent(_ event: NSEvent) {
        // Phase 1 先只验证实体像素区能吃到点击，拖拽逻辑后面再接。
        if event.type == .leftMouseDown, petWebView.shouldHandleMouse(at: event.locationInWindow) {
            print("hit pet")
        }

        super.sendEvent(event)
    }

    /// 状态机已经选好了最终展示的 SVG，这里只负责把结果推给 WebView。
    func display(state _: PetState, svgFilename: String) {
        petWebView.loadSVG(svgFilename)
    }
}
