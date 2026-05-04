import AppKit
import Sparkle

/// Sparkle 自动更新的轻量包装。
/// 仅在 release 构建中由 `AppDelegate` 通过 `ClawdEnableSparkleUpdater` Info.plist 键启用，
/// 调试构建保持禁用以避免在本地开发时误触发更新检查。
@MainActor
final class SparkleUpdater {
    let controller: SPUStandardUpdaterController

    init() {
        // 直接使用 Sparkle 标准控制器，让菜单项和原生更新 UI 走官方默认流程。
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// 提供给菜单项 `target/action` 直接绑定的 selector，避免菜单层重复持有 controller。
    var checkForUpdatesAction: Selector {
        #selector(SPUStandardUpdaterController.checkForUpdates(_:))
    }

    /// 用于动态决定菜单项的 enabled 状态——例如更新检查正在进行时禁用入口。
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
