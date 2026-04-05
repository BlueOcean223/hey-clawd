import AppKit
import SwiftUI

@MainActor
final class BubbleWindow: NSPanel {
    private let hostingView: NSHostingView<BubbleView>
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
        hostingView = NSHostingView(rootView: view)

        let size = NSSize(width: 340, height: content.estimatedHeight)
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
        hostingView.frame = NSRect(origin: .zero, size: size)
        setFrame(bottomRightRect(for: size), display: false)
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
        let fittingSize = hostingView.fittingSize
        let nextHeight = max(160, ceil(fittingSize.height))

        guard abs(frame.height - nextHeight) > 1 else {
            return
        }

        // 保持底边不动，只把实际高度向上长出来，方便后续 4.2 直接接堆叠布局。
        var nextFrame = frame
        nextFrame.size.height = nextHeight
        setFrame(nextFrame, display: true)
        onHeightDidChange?()
    }
}
