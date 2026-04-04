import SwiftUI

/// 无主窗口的菜单栏 App，所有 UI 逻辑交由 AppDelegate 驱动。
@main
struct HeyClawdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 仅声明 Settings 场景以满足 App 协议要求；不展示任何窗口
        Settings {
            EmptyView()
        }
    }
}
