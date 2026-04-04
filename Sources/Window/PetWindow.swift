import AppKit

/// 桌面宠物的透明无边框悬浮窗口。
final class PetWindow: NSWindow {
    /// 宠物窗口尺寸档位，正方形边长（pt）
    enum SizePreset {
        case small   // 200
        case medium  // 280
        case large   // 360

        var dimension: CGFloat {
            switch self {
            case .small:  return 200
            case .medium: return 280
            case .large:  return 360
            }
        }
    }

    init(sizePreset: SizePreset = .small) {
        let size = NSSize(width: sizePreset.dimension, height: sizePreset.dimension)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // 透明无边框，悬浮于所有窗口之上
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false

        // 接收鼠标事件；拖拽后续通过自定义鼠标事件处理实现
        ignoresMouseEvents = false
        isMovableByWindowBackground = false

        // 切换桌面时窗口保持可见
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        setFrame(originRect(for: size), display: false)
    }

    /// 计算初始位置：屏幕右下角，留出边距
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
}
