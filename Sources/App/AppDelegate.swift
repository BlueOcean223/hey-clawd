import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem!
    private(set) var petWindow: PetWindow?
    private var httpServer: HTTPServer?
    private var httpServerTask: Task<Void, Never>?
    private var terminationSignalSources: [DispatchSourceSignal] = []

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

        let server = HTTPServer()
        server.setStateRequestHandler { _ in
            // Phase 2.2 再把 JSON payload 接进状态机。
        }
        server.setPermissionRequestHandler { request in
            // Phase 2.4 之前先默认拒绝，避免连接一直挂住。
            request.respond(with: PermissionBehavior.deny)
        }
        httpServer = server
        httpServerTask = Task { [server] in
            _ = await server.start()
        }
        installTerminationSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        httpServerTask?.cancel()
        httpServer?.stop()
    }

    private func installTerminationSignalHandlers() {
        let signals = [SIGINT, SIGTERM]

        terminationSignalSources = signals.map { signalValue in
            signal(signalValue, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
            source.setEventHandler { [weak self] in
                self?.httpServerTask?.cancel()
                self?.httpServer?.stop()
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            return source
        }
    }
}
