import AppKit
import Sparkle

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

    var checkForUpdatesAction: Selector {
        #selector(SPUStandardUpdaterController.checkForUpdates(_:))
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
