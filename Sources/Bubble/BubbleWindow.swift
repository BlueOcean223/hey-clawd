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

@MainActor
final class BubbleWindow: NSPanel {
    private let hostingView: ClickThroughHostingView<BubbleView>
    private let minimumHeight: CGFloat
    var onHeightDidChange: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    init(content: PermissionBubbleContent, onDecide: @escaping (PermissionDecision) -> Void) {
        let view = BubbleView(
            toolName: content.toolName,
            toolInput: content.toolInput,
            suggestions: content.suggestions,
            onDecide: onDecide
        )
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
        isReleasedWhenClosed = false

        contentView = hostingView
        setFrame(bottomRightRect(for: size), display: false)

        hostingView.rootView.onContentHeightChanged = { [weak self] in
            self?.updateHeightToFitContent()
        }
    }

    func present() {
        orderFrontRegardless()

        DispatchQueue.main.async { [weak self] in
            self?.updateHeightToFitContent()
        }
    }

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
