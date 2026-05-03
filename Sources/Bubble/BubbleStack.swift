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
        let previousApp: NSRunningApplication?
        let previousAppBundleId: String?
    }

    private let petWindowProvider: @MainActor () -> PetWindow?
    private let bubbleFollowProvider: @MainActor () -> Bool

    private var pendingPermissions: [PendingBubble] = []
    private var petObservationTokens: [NSObjectProtocol] = []
    var onBubblesChanged: (() -> Void)?

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

    var pendingCount: Int {
        pendingPermissions.count
    }

    func countMatching(sessionId: String, toolName: String, toolInputHash: String) -> Int {
        pendingPermissions.filter {
            $0.content.sessionId == sessionId &&
                $0.content.toolName == toolName &&
                $0.content.toolInputHash == toolInputHash
        }.count
    }

    /// 当 /state 收到 PostToolUse / PostToolUseFailure 且 hash 唯一匹配某个待决气泡时，
    /// 关闭那唯一一个气泡（响应 .undecided）。返回是否关闭。
    @discardableResult
    func dismissBubbleMatchingTerminalApproval(
        sessionId: String,
        toolName: String,
        toolInputHash: String
    ) -> Bool {
        let matches = pendingPermissions.filter {
            $0.content.sessionId == sessionId &&
                $0.content.toolName == toolName &&
                $0.content.toolInputHash == toolInputHash
        }

        guard matches.count == 1, let bubble = matches.first else {
            return false
        }

        removeBubble(id: bubble.id, respondingWith: .simple(.undecided))
        return true
    }

    func enqueue(
        content: PermissionBubbleContent,
        request: PendingPermissionRequest,
        previousApp: NSRunningApplication? = nil,
        previousAppBundleId: String? = nil
    ) {
        guard request.isAwaitingDecision else {
            return
        }

        let id = UUID()
        let window = BubbleWindow(
            content: content,
            onDismiss: { [weak self] in
                self?.removeBubble(id: id, respondingWith: .simple(.undecided))
            },
            onDecide: { [weak self] decision in
                self?.resolveBubble(id: id, decision: decision)
            }
        )
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
                window: window,
                previousApp: previousApp,
                previousAppBundleId: previousAppBundleId ?? previousApp?.bundleIdentifier
            )
        )

        onBubblesChanged?()
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
            let clampedY = min(currentY, visibleFrame.maxY - size.height)
            let finalY = max(visibleFrame.minY, clampedY)
            let nextOrigin = NSPoint(
                x: clampedX(for: size.width, anchor: anchor, visibleFrame: visibleFrame, followPet: shouldUsePetAnchor),
                y: finalY
            )
            window.setFrameOrigin(nextOrigin)
            currentY += size.height + 6
        }
    }

    func observePetWindow(_ petWindow: NSWindow) {
        stopObservingPetWindow()

        let center = NotificationCenter.default
        let moveToken = center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: petWindow,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionBubbles()
            }
        }
        let resizeToken = center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: petWindow,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionBubbles()
            }
        }
        petObservationTokens = [moveToken, resizeToken]
    }

    func stopObservingPetWindow() {
        for token in petObservationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        petObservationTokens.removeAll()
    }

    func dismissAll(respondingWith behavior: PermissionBehavior) {
        let ids = pendingPermissions.map(\.id)
        for id in ids {
            removeBubble(id: id, respondingWith: .simple(behavior))
        }
    }

    func denyAllForDoNotDisturb() {
        // DND 打开时不替用户做决策，回 undecided 让 Claude Code 回退到终端提示。
        dismissAll(respondingWith: .undecided)
    }

    func allowLatestBubble() {
        guard let latestBubble = pendingPermissions.last else {
            return
        }

        resolveBubble(id: latestBubble.id, decision: .allow)
    }

    func denyLatestBubble() {
        guard let latestBubble = pendingPermissions.last else {
            return
        }

        resolveBubble(id: latestBubble.id, decision: .deny)
    }

    func allowLatestBubbleRestoringFocus() {
        resolveLatestBubbleRestoringFocus(decision: .allow)
    }

    func denyLatestBubbleRestoringFocus() {
        resolveLatestBubbleRestoringFocus(decision: .deny)
    }

    private func resolveBubble(id: UUID, decision: PermissionDecision) {
        let result = PermissionDecisionResult(
            behavior: decision.behavior,
            suggestionPayloads: decision.suggestionPayloads
        )
        removeBubble(id: id, respondingWith: result)
    }

    private func resolveLatestBubbleRestoringFocus(decision: PermissionDecision) {
        guard let latestBubble = pendingPermissions.last else {
            return
        }

        let previousApp = latestBubble.previousApp
        let previousAppBundleId = latestBubble.previousAppBundleId
        resolveBubble(id: latestBubble.id, decision: decision)
        scheduleFocusRestore(to: previousApp, bundleId: previousAppBundleId)
    }

    private func scheduleFocusRestore(to app: NSRunningApplication?, bundleId: String?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let app, !app.isTerminated {
                app.activate(options: [])
                return
            }

            if let bundleId,
               let fallback = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId)
                .first(where: { !$0.isTerminated }) {
                fallback.activate(options: [])
            }
        }
    }

    private func removeBubble(id: UUID, respondingWith result: PermissionDecisionResult?) {
        guard let index = pendingPermissions.firstIndex(where: { $0.id == id }) else {
            return
        }

        let bubble = pendingPermissions.remove(at: index)
        bubble.window.close()
        bubble.request.clearDisconnectHandler()

        if let result {
            bubble.request.respond(with: result)
        }

        onBubblesChanged?()
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
        let petWindow = petWindowProvider()
        let petIsVisible = petWindow?.isVisible == true

        if followPet, petIsVisible, let petFrame = petWindow?.frame {
            // 跟随桌宠：X/Y 都以桌宠为基准。
            return NSRect(
                x: max(visibleFrame.minX + 8, petFrame.minX - 8),
                y: max(visibleFrame.minY + 8, petFrame.minY + 8),
                width: 0,
                height: max(0, petFrame.height)
            )
        }

        // 高度回退时：Y 从屏幕底部开始，但 X 仍然偏移到桌宠左侧以免遮挡。
        if petIsVisible, let petFrame = petWindow?.frame {
            return NSRect(
                x: max(visibleFrame.minX + 8, petFrame.minX - 8),
                y: visibleFrame.minY + 8,
                width: 0,
                height: 0
            )
        }

        // 无桌宠时，右下角。
        return NSRect(
            x: visibleFrame.maxX - 8,
            y: visibleFrame.minY + 8,
            width: 0,
            height: 0
        )
    }

    private func clampedX(for width: CGFloat, anchor: NSRect, visibleFrame: NSRect, followPet: Bool) -> CGFloat {
        // 始终放在锚点左侧，无论是否 followPet。
        let preferredX = anchor.minX - width
        return min(
            max(visibleFrame.minX + 8, preferredX),
            visibleFrame.maxX - width - 8
        )
    }

    private func targetScreen() -> NSScreen {
        petWindowProvider()?.screen ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}
