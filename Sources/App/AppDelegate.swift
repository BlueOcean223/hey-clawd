import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem!
    private(set) var petWindow: PetWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 配合 Info.plist LSUIElement=true，隐藏 Dock 图标
        NSApp.setActivationPolicy(.accessory)

        // 菜单栏图标占位，后续替换为宠物头像/状态指示
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.title = " "
            button.toolTip = "hey-clawd"
        }

        // 创建桌面宠物窗口并显示
        petWindow = PetWindow(sizePreset: .small)
        petWindow?.orderFront(nil)
    }
}
