import AppKit
import Foundation

@MainActor
final class BubbleStack {
    static let passthroughTools: Set<String> = [
        "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskStop", "TaskOutput",
    ]

    private struct PendingBubble {
        let id: UUID
        let request: PendingPermissionRequest
        let content: PermissionBubbleContent
        let window: BubbleWindow
    }

    private let petWindowProvider: @MainActor () -> PetWindow?
    private let bubbleFollowProvider: @MainActor () -> Bool

    private var pendingPermissions: [PendingBubble] = []

    init(
        petWindowProvider: @escaping @MainActor () -> PetWindow?,
        bubbleFollowProvider: @escaping @MainActor () -> Bool
    ) {
        self.petWindowProvider = petWindowProvider
        self.bubbleFollowProvider = bubbleFollowProvider
    }

    var hasVisibleBubbles: Bool {
        !pendingPermissions.isEmpty
    }

    func enqueue(content: PermissionBubbleContent, request: PendingPermissionRequest) {
        guard request.isAwaitingDecision else {
            return
        }

        let id = UUID()
        let window = BubbleWindow(content: content) { [weak self] decision in
            self?.resolveBubble(id: id, behavior: decision.behavior)
        }
        window.onHeightDidChange = { [weak self] in
            self?.repositionBubbles()
        }

        request.setDisconnectHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.removeBubble(id: id, respondingWith: nil)
            }
        }

        pendingPermissions.append(
            PendingBubble(
                id: id,
                request: request,
                content: content,
                window: window
            )
        )

        repositionBubbles()
        window.present()
    }

    func repositionBubbles() {
        guard !pendingPermissions.isEmpty else {
            return
        }

        let screen = targetScreen()
        let visibleFrame = screen.visibleFrame
        let totalHeight = stackHeight()
        // 跟随桌宠时，堆叠太高会遮住主要工作区，超过半屏就退回右下角。
        let shouldUsePetAnchor = bubbleFollowProvider() &&
            petWindowProvider()?.isVisible == true &&
            totalHeight <= visibleFrame.height * 0.5

        let anchor = anchorRect(in: visibleFrame, followPet: shouldUsePetAnchor)
        var currentY = anchor.minY

        // 最新气泡放在最底部，旧气泡继续向上堆。
        for bubble in pendingPermissions.reversed() {
            let window = bubble.window
            let size = window.frame.size
            let nextOrigin = NSPoint(
                x: clampedX(for: size.width, anchor: anchor, visibleFrame: visibleFrame, followPet: shouldUsePetAnchor),
                y: currentY
            )
            window.setFrameOrigin(nextOrigin)
            currentY += size.height + 6
        }
    }

    func dismissAll(respondingWith behavior: PermissionBehavior) {
        let ids = pendingPermissions.map(\.id)
        for id in ids {
            removeBubble(id: id, respondingWith: behavior)
        }
    }

    private func resolveBubble(id: UUID, behavior: PermissionBehavior) {
        removeBubble(id: id, respondingWith: behavior)
    }

    private func removeBubble(id: UUID, respondingWith behavior: PermissionBehavior?) {
        guard let index = pendingPermissions.firstIndex(where: { $0.id == id }) else {
            return
        }

        let bubble = pendingPermissions.remove(at: index)
        bubble.window.close()
        bubble.request.clearDisconnectHandler()

        if let behavior {
            bubble.request.respond(with: behavior)
        }

        repositionBubbles()
    }

    private func stackHeight() -> CGFloat {
        let heights = pendingPermissions.reduce(CGFloat.zero) { partial, bubble in
            partial + max(bubble.window.frame.height, bubble.content.estimatedHeight)
        }
        let spacing = CGFloat(max(pendingPermissions.count - 1, 0) * 6)
        return heights + spacing + 16
    }

    private func anchorRect(in visibleFrame: NSRect, followPet: Bool) -> NSRect {
        guard
            followPet,
            let petWindow = petWindowProvider(),
            petWindow.isVisible
        else {
            // 不跟随桌宠时，直接按工作区右下角作为堆叠基准点。
            return NSRect(
                x: visibleFrame.maxX - 8,
                y: visibleFrame.minY + 8,
                width: 0,
                height: 0
            )
        }

        let petFrame = petWindow.frame
        return NSRect(
            x: max(visibleFrame.minX + 8, petFrame.minX - 8),
            y: max(visibleFrame.minY + 8, petFrame.minY + 8),
            width: 0,
            height: max(0, petFrame.height)
        )
    }

    private func clampedX(for width: CGFloat, anchor: NSRect, visibleFrame: NSRect, followPet: Bool) -> CGFloat {
        let preferredX: CGFloat
        if followPet {
            preferredX = anchor.minX - width
        } else {
            preferredX = visibleFrame.maxX - width - 8
        }

        return min(
            max(visibleFrame.minX + 8, preferredX),
            visibleFrame.maxX - width - 8
        )
    }

    private func targetScreen() -> NSScreen {
        petWindowProvider()?.screen ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}
