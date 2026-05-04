import AppKit
import Foundation

/// 屏幕上"权限气泡"的队列与堆叠管理器。
///
/// 每条 hook 端通过 `/permission` 进来的请求会在这里登记一条 `PendingBubble`；
/// HTTPServer 把 `PendingPermissionRequest` 这个握住 `CheckedContinuation` 的对象交给我们，
/// 由用户点击或快捷键触发的 `removeBubble` 通过 `request.respond(_:)` 送回决策。
/// 所有副作用（窗口、客户端断连、UI 通知）都集中在这一层，避免散落到 HTTP/UI 多处。
@MainActor
final class BubbleStack {
    /// 这些工具属于"无害的子任务调度"，不弹气泡直接放行——hook 端会校验同样的清单。
    static let passthroughTools: Set<String> = [
        "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskStop", "TaskOutput",
    ]

    /// 单条气泡的内部记录。`previousApp` / `previousAppBundleId` 用于响应快捷键决策时
    /// 把焦点送回用户原先所在的应用，避免气泡偷走焦点后回不去。
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
    /// 跟随模式下监听桌宠移动/缩放的通知 token；切换跟随状态时整体 remove。
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

    /// 由 HTTPServer 在去重判定时调用：同 sessionId+toolName+inputHash 的待决气泡数。
    func countMatching(sessionId: String, toolName: String, toolInputHash: String) -> Int {
        pendingPermissions.filter {
            $0.content.sessionId == sessionId &&
                $0.content.toolName == toolName &&
                $0.content.toolInputHash == toolInputHash
        }.count
    }

    /// 当 /state 收到工具完成事件且 hash 唯一匹配某个待决气泡时，
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

        // 仅在唯一匹配时关闭：避免多条等待同一工具 + 同一参数的气泡被一锅端，
        // 那种情况通常意味着用户在终端真的进行了多次确认，气泡需要分别处理。
        guard matches.count == 1, let bubble = matches.first else {
            return false
        }

        removeBubble(id: bubble.id, respondingWith: .simple(.undecided))
        return true
    }

    /// 入队新的权限请求并立刻显示气泡。
    /// - Important: `request` 内部持有 `CheckedContinuation`，这条路径**必须**最终走到
    ///   `removeBubble(_:respondingWith:)`，否则会泄漏 continuation 并卡住 hook 调用方。
    func enqueue(
        content: PermissionBubbleContent,
        request: PendingPermissionRequest,
        previousApp: NSRunningApplication? = nil,
        previousAppBundleId: String? = nil
    ) {
        // 调用方已经断连或别的渠道决议过，立刻丢弃，不要弹一个空气泡。
        guard request.isAwaitingDecision else {
            return
        }

        let id = UUID()
        let window = BubbleWindow(
            content: content,
            onDismiss: { [weak self] in
                // 用户拖走气泡或被外部强制关闭：回 undecided 让 hook 走默认提示。
                self?.removeBubble(id: id, respondingWith: .simple(.undecided))
            },
            onDecide: { [weak self] decision in
                self?.resolveBubble(id: id, decision: decision)
            }
        )
        window.onHeightDidChange = { [weak self] in
            self?.repositionBubbles()
        }

        // hook 客户端断连（终端被关闭、Ctrl+C 等）时不再弹决策回去，直接清理 UI。
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

    /// 重排所有可见气泡。
    /// 触发场景：新气泡入队、气泡关闭、气泡内容高度变化、桌宠位置变化、跟随开关切换。
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
            // 防止单条气泡顶到屏幕外：上下都做 clamp。
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

    /// 监听桌宠窗口移动/缩放以联动重排；跟随模式开关切换时由调用方触发 stop+observe。
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

    /// 一次性清空所有气泡并向 hook 端回送统一决策。
    /// 复制 id 列表是为了在迭代中安全调用 `removeBubble`（后者会改 `pendingPermissions`）。
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

    /// 快捷键 Allow/Deny 入口：决策后再把焦点丢回用户原先在用的 app。
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

        // 先抓取信息再 resolve——resolve 会把 bubble 从队列移除导致字段丢失。
        let previousApp = latestBubble.previousApp
        let previousAppBundleId = latestBubble.previousAppBundleId
        resolveBubble(id: latestBubble.id, decision: decision)
        scheduleFocusRestore(to: previousApp, bundleId: previousAppBundleId)
    }

    /// 给 macOS WindowServer 0.3s 把气泡窗口真正下台，再请求激活，避免抢焦点失败。
    private func scheduleFocusRestore(to app: NSRunningApplication?, bundleId: String?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let app, !app.isTerminated {
                app.activate(options: [])
                return
            }

            // 原 app 已退出：用 bundleId 兜底找一个同 app 的实例（多窗口终端常见）。
            if let bundleId,
               let fallback = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId)
                .first(where: { !$0.isTerminated }) {
                fallback.activate(options: [])
            }
        }
    }

    /// 销毁气泡 + 通知 hook 客户端 + 触发重排。
    /// `result == nil` 用于 disconnect 路径：连接已断不再尝试响应，但仍需清 UI。
    private func removeBubble(id: UUID, respondingWith result: PermissionDecisionResult?) {
        guard let index = pendingPermissions.firstIndex(where: { $0.id == id }) else {
            return
        }

        let bubble = pendingPermissions.remove(at: index)
        bubble.window.close()
        // 断开 disconnect handler，避免后续连接关闭时再触发一次 removeBubble。
        bubble.request.clearDisconnectHandler()

        if let result {
            bubble.request.respond(with: result)
        }

        onBubblesChanged?()
        repositionBubbles()
    }

    /// 估算堆叠总高度：每个气泡的实际/预估高度取大者，加上 6pt 间距和 16pt 顶端预留。
    private func stackHeight() -> CGFloat {
        let heights = pendingPermissions.reduce(CGFloat.zero) { partial, bubble in
            partial + max(bubble.window.frame.height, bubble.content.estimatedHeight)
        }
        let spacing = CGFloat(max(pendingPermissions.count - 1, 0) * 6)
        return heights + spacing + 16
    }

    /// 计算锚点矩形。三种情况：
    /// 1. 跟随桌宠且高度可控：以桌宠左侧 + 桌宠底部为锚点；
    /// 2. 桌宠存在但高度超限：X 仍贴桌宠左侧，Y 退回屏幕底部；
    /// 3. 桌宠隐藏：直接靠右下角。
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

    /// X 轴定位：永远把气泡右边贴在锚点处，再夹到屏幕可见范围内（左右各留 8pt 边距）。
    private func clampedX(for width: CGFloat, anchor: NSRect, visibleFrame: NSRect, followPet: Bool) -> CGFloat {
        // 始终放在锚点左侧，无论是否 followPet。
        let preferredX = anchor.minX - width
        return min(
            max(visibleFrame.minX + 8, preferredX),
            visibleFrame.maxX - width - 8
        )
    }

    /// 选择渲染屏幕：优先桌宠所在屏，桌宠不可见时退主屏；都缺失时返回任意屏避免崩溃。
    private func targetScreen() -> NSScreen {
        petWindowProvider()?.screen ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}
