import AppKit

/// 状态栏（菜单栏）按钮的总控类。
///
/// 职责拆分：本类只关心 NSStatusItem 的生命周期、点击行为和回调路由；
/// 真正的菜单结构在 `MenuBuilder` 里描述。`AppDelegate` 通过设置 `on*` closure
/// 注入业务行为，便于把 UI 与状态机/偏好/HookInstaller 解耦。
@MainActor
final class StatusBarController: NSObject {
    private let stateProvider: @MainActor () -> AppMenuState
    private let statusItem: NSStatusItem

    var onTogglePetVisibility: @MainActor () -> Void = {}
    var onSelectSizePercent: @MainActor (Int) -> Void = { _ in }
    var onSelectCustomSize: @MainActor () -> Void = {}
    var onToggleMiniMode: @MainActor (Bool) -> Void = { _ in }
    var onToggleDoNotDisturb: @MainActor (Bool) -> Void = { _ in }
    var onToggleBubbleFollow: @MainActor (Bool) -> Void = { _ in }
    var onToggleHideBubbles: @MainActor (Bool) -> Void = { _ in }
    var onToggleSoundEffects: @MainActor (Bool) -> Void = { _ in }
    var onToggleAutoFocusSession: @MainActor (Bool) -> Void = { _ in }
    var onSelectLanguage: @MainActor (AppLanguage) -> Void = { _ in }
    var onCheckForUpdates: @MainActor () -> Void = {}
    var onRegisterHooks: @MainActor (HookInstaller.HookTarget?) -> Void = { _ in }
    var onUnregisterHooks: @MainActor (HookInstaller.HookTarget?) -> Void = { _ in }
    var onQuit: @MainActor () -> Void = {}
    var onFocusSession: @MainActor (SessionMenuSnapshot) -> Void = { _ in }
    /// Sparkle 菜单项需要把 target/action 直接绑到 SPUStandardUpdaterController 上，
    /// 否则更新窗口的"上下文敏感按钮"无法工作；这里只做透传持有。
    var checkForUpdatesMenuTarget: AnyObject?
    var checkForUpdatesMenuAction: Selector?
    var shouldShowCheckForUpdatesMenu: @MainActor () -> Bool = { false }
    var canCheckForUpdatesMenu: @MainActor () -> Bool = { false }

    init(stateProvider: @escaping @MainActor () -> AppMenuState) {
        self.stateProvider = stateProvider
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
    }

    var item: NSStatusItem {
        statusItem
    }

    /// 每次右键打开菜单时重新构建，确保会话列表/勾选状态一定是最新的。
    func makeMenu() -> NSMenu {
        MenuBuilder.build(state: stateProvider(), target: self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.image = trayImage()
        button.imagePosition = .imageOnly
        // 极少数情况下 image 渲染失败（例如沙盒中的资源问题），用 "C" 字母兜底。
        button.title = button.image == nil ? "C" : ""
        button.toolTip = "hey-clawd"
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        // 同时监听左右键 mouseUp，区分"显示桌宠"和"打开菜单"两种意图。
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 把 clawd-static-base.svg（15×16 像素网格）缩放绘制到 18pt template icon。
    /// 躯干在眼窝处分块绘制，留出透明眼孔让角色更有辨识度。
    private func trayImage() -> NSImage? {
        let imgH: CGFloat = 22
        let s: CGFloat = imgH / 16.0
        let imgW: CGFloat = 15.0 * s
        let image = NSImage(size: NSSize(width: imgW, height: imgH), flipped: true) { _ in
            let ox: CGFloat = 0
            NSColor.black.setFill()

            // 内嵌 helper：按 15×16 像素网格描述的矩形坐标缩放后填充。
            func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
                NSRect(x: ox + x * s, y: y * s, width: w * s, height: h * s).fill()
            }

            fill(2, 3, 11, 2)   // 头顶到眼睛上方
            fill(2, 5, 2, 2)    // 左眼左侧
            fill(5, 5, 5, 2)    // 两眼之间
            fill(11, 5, 2, 2)   // 右眼右侧
            fill(2, 7, 11, 3)   // 眼下到腰部
            fill(0, 6, 2, 2)    // 左臂
            fill(13, 6, 2, 2)   // 右臂
            fill(3, 10, 1, 2)   // 四足
            fill(5, 10, 1, 2)
            fill(9, 10, 1, 2)
            fill(11, 10, 1, 2)

            return true
        }
        // template 模式让 macOS 自动适配明暗外观。
        image.isTemplate = true
        return image
    }

    /// 借助 `performClick` 弹出菜单，再把 `statusItem.menu` 立刻清空——
    /// 这样左键点击不会被 menu 拦截，依然能触发 toggle 桌宠。
    private func showMenu() {
        let menu = makeMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            onTogglePetVisibility()
        }
    }

    @objc func selectSizePercent(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else {
            return
        }
        onSelectSizePercent(percent)
    }

    @objc func selectCustomSize(_ sender: NSMenuItem) {
        onSelectCustomSize()
    }

    @objc func toggleMiniMode(_ sender: NSMenuItem) {
        onToggleMiniMode(sender.state != .on)
    }

    @objc func focusSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionMenuSnapshot else {
            return
        }

        onFocusSession(session)
    }

    @objc func toggleDoNotDisturb(_ sender: NSMenuItem) {
        // 用 stateProvider 当真值源——避免 sender.state 与实际偏好脱节。
        onToggleDoNotDisturb(!stateProvider().isDoNotDisturbEnabled)
    }

    @objc func toggleBubbleFollow(_ sender: NSMenuItem) {
        onToggleBubbleFollow(sender.state != .on)
    }

    @objc func toggleHideBubbles(_ sender: NSMenuItem) {
        onToggleHideBubbles(sender.state != .on)
    }

    @objc func toggleSoundEffects(_ sender: NSMenuItem) {
        onToggleSoundEffects(sender.state != .on)
    }

    @objc func toggleAutoFocusSession(_ sender: NSMenuItem) {
        onToggleAutoFocusSession(sender.state != .on)
    }

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? AppLanguage else {
            return
        }
        onSelectLanguage(language)
    }

    @objc func checkForUpdates(_ sender: NSMenuItem) {
        onCheckForUpdates()
    }

    @objc func registerHooks(_ sender: NSMenuItem) {
        // representedObject 可能为 nil，对应"重新注册全部 hook"的语义。
        onRegisterHooks(sender.representedObject as? HookInstaller.HookTarget)
    }

    @objc func unregisterHooks(_ sender: NSMenuItem) {
        onUnregisterHooks(sender.representedObject as? HookInstaller.HookTarget)
    }

    @objc func togglePetVisibility(_ sender: NSMenuItem) {
        onTogglePetVisibility()
    }

    @objc func quit(_ sender: NSMenuItem) {
        onQuit()
    }
}
