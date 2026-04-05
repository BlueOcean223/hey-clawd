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
    var onQuit: @MainActor () -> Void = {}
    var onFocusSession: @MainActor (pid_t?) -> Void = { _ in }

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

    private func trayImage() -> NSImage? {
        let image = NSImage(named: "tray-icon")
            ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "hey-clawd")
            ?? NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "hey-clawd")
        image?.isTemplate = true
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
        onFocusSession(sender.representedObject as? pid_t)
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

    @objc func togglePetVisibility(_ sender: NSMenuItem) {
        onTogglePetVisibility()
    }

    @objc func quit(_ sender: NSMenuItem) {
        onQuit()
    }
}
