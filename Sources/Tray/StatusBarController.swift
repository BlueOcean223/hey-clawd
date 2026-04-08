import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let stateProvider: @MainActor () -> AppMenuState
    private let statusItem: NSStatusItem

    var onTogglePetVisibility: @MainActor () -> Void = {}
    var onSelectSizePreset: @MainActor (PetWindow.SizePreset) -> Void = { _ in }
    var onToggleMiniMode: @MainActor (Bool) -> Void = { _ in }
    var onToggleDoNotDisturb: @MainActor (Bool) -> Void = { _ in }
    var onToggleBubbleFollow: @MainActor (Bool) -> Void = { _ in }
    var onToggleHideBubbles: @MainActor (Bool) -> Void = { _ in }
    var onToggleSoundEffects: @MainActor (Bool) -> Void = { _ in }
    var onSelectLanguage: @MainActor (AppLanguage) -> Void = { _ in }
    var onCheckForUpdates: @MainActor () -> Void = {}
    var onRegisterHooks: @MainActor (HookInstaller.HookTarget?) -> Void = { _ in }
    var onUnregisterHooks: @MainActor (HookInstaller.HookTarget?) -> Void = { _ in }
    var onQuit: @MainActor () -> Void = {}
    var onFocusSession: @MainActor (SessionMenuSnapshot) -> Void = { _ in }
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

    func makeMenu() -> NSMenu {
        MenuBuilder.build(state: stateProvider(), target: self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.image = trayImage()
        button.imagePosition = .imageOnly
        button.title = button.image == nil ? "C" : ""
        button.toolTip = "hey-clawd"
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
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
        image.isTemplate = true
        return image
    }

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

    @objc func selectSizePreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? PetWindow.SizePreset else {
            return
        }
        onSelectSizePreset(preset)
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
