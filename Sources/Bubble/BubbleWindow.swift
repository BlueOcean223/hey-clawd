import AppKit
import SwiftUI

/// NSHostingView 默认 acceptsFirstMouse 返回 false，
/// 导致非 key window 上的首次点击被消耗为"选中窗口"而非按钮点击。
/// 对于 nonactivatingPanel 浮窗，必须返回 true 才能一击即中。
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// 屏幕右下角弹出的"权限确认"浮窗。
///
/// 使用 `nonactivatingPanel` 是为了不抢走当前终端的焦点——用户阅读完气泡后还可以
/// 直接回到键盘上继续敲命令。窗口本身不进入 mission control / spaces 切换，
/// 通过 `canJoinAllSpaces + stationary` 钉死在所有桌面的同一位置。
@MainActor
final class BubbleWindow: NSPanel {
    private let hostingView: ClickThroughHostingView<BubbleView>
    private let minimumHeight: CGFloat
    /// SwiftUI 内容自适应高度后回调；`BubbleStack` 据此重新堆叠相邻气泡。
    var onHeightDidChange: (() -> Void)?

    /// 必须返回 true，否则气泡里的按钮在窗口未激活时无法接收键盘事件（例如快捷键确认）。
    override var canBecomeKey: Bool {
        true
    }

    /// 主窗口语义不适合一个临时浮层；保持 false 防止 `mainMenu` 之类的状态被错误绑定。
    override var canBecomeMain: Bool {
        false
    }

    init(content: PermissionBubbleContent, onDismiss: @escaping () -> Void, onDecide: @escaping (PermissionDecision) -> Void) {
        var view = BubbleView(
            toolName: content.toolName,
            toolInput: content.toolInput,
            suggestions: content.suggestions,
            onDecide: onDecide
        )
        view.onDismiss = onDismiss
        hostingView = ClickThroughHostingView(rootView: view)
        minimumHeight = content.estimatedHeight

        // 用宽裕高度预测量，让 fixedSize 的 VStack 计算出真实理想高度。
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: 340, height: 600))
        let measuredHeight = ceil(hostingView.fittingSize.height)
        let actualHeight = max(minimumHeight, measuredHeight)
        let size = NSSize(width: 340, height: actualHeight)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hidesOnDeactivate = false
        // 关闭时不要 release，BubbleStack 仍持有引用并可能复用做退场动画。
        isReleasedWhenClosed = false

        contentView = hostingView
        setFrame(bottomRightRect(for: size), display: false)

        hostingView.rootView.onContentHeightChanged = { [weak self] in
            self?.updateHeightToFitContent()
        }
    }

    /// 显示窗口但不抢焦点（`orderFrontRegardless` 不激活 app）。
    /// 异步再做一次高度对齐，因为 SwiftUI 在窗口真正上屏后才稳定布局。
    func present() {
        orderFrontRegardless()

        DispatchQueue.main.async { [weak self] in
            self?.updateHeightToFitContent()
        }
    }

    /// 计算屏幕右下角的目标坐标，留 24pt 安全边距避开 Dock 与屏幕圆角。
    private func bottomRightRect(for size: NSSize) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - 24,
            y: visibleFrame.minY + 24
        )
        return NSRect(origin: origin, size: size)
    }

    /// 内容高度变化（例如展开 suggestions）时同步窗口外框。
    /// 1pt 阈值用来过滤浮点抖动，避免反复 setFrame 导致 BubbleStack 重排闪烁。
    private func updateHeightToFitContent() {
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = ceil(hostingView.fittingSize.height)
        let nextHeight = max(minimumHeight, fittingHeight)

        guard abs(frame.height - nextHeight) > 1 else {
            return
        }

        var nextFrame = frame
        nextFrame.size.height = nextHeight
        setFrame(nextFrame, display: true)
        onHeightDidChange?()
    }
}
