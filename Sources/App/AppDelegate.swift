import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem!
    private(set) var petWindow: PetWindow?
    private var httpServer: HTTPServer?
    private var httpServerTask: Task<Void, Never>?
    private var stateMachine: StateMachine?
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

        assembleCoreLoop()
        installTerminationSignalHandlers()
    }

    /// 2.4 的核心装配点：
    /// HTTPServer 接收 hook 请求，StateMachine 决定最终状态和 SVG，
    /// 再由 PetWindow/PetWebView 把结果推到 bridge.js。
    @MainActor
    private func assembleCoreLoop() {
        let stateMachine = StateMachine()
        stateMachine.onStateChange = { [weak petWindow = self.petWindow] state, svg in
            petWindow?.display(state: state, svgFilename: svg)
        }
        self.stateMachine = stateMachine

        let server = HTTPServer()
        server.setStateRequestHandler { body in
            Self.handleStateRequest(body, using: stateMachine)
        }
        server.setPermissionRequestHandler { request in
            // Phase 2.4 只打通 state 链路；权限气泡留到后续任务再接。
            request.respond(with: PermissionBehavior.deny)
        }
        httpServer = server
        httpServerTask = Task { [server] in
            _ = await server.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        httpServerTask?.cancel()
        httpServer?.stop()
        stateMachine?.cleanup()
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

    /// /state 只接受轻量 JSON，先在这里做字段清洗，再交给 StateMachine 聚合。
    @MainActor
    private static func handleStateRequest(_ body: Data, using stateMachine: StateMachine) -> HTTPResponse {
        guard
            let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let rawState = payload["state"] as? String,
            let state = PetState(rawValue: rawState)
        else {
            return errorResponse(statusCode: 400, message: "unknown state")
        }

        let sessionId = (payload["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = payload["event"] as? String
        let svgUpdate = extractSVGUpdate(from: payload)
        let sourcePid = normalizedPID(payload["source_pid"])
        let cwd = normalizedString(payload["cwd"] as? String)
        let agentId = normalizedString(payload["agent_id"] as? String)
        let headless = payload["headless"] as? Bool ?? false

        switch svgUpdate {
        case .unspecified:
            stateMachine.setState(
                state,
                sessionId: sessionId ?? "default",
                event: event,
                svg: nil,
                svgWasProvided: false,
                sourcePid: sourcePid,
                cwd: cwd,
                agentId: agentId,
                headless: headless
            )
        case .explicit(let svg):
            stateMachine.setState(
                state,
                sessionId: sessionId ?? "default",
                event: event,
                svg: svg,
                svgWasProvided: true,
                sourcePid: sourcePid,
                cwd: cwd,
                agentId: agentId,
                headless: headless
            )
        case .invalid:
            return errorResponse(statusCode: 400, message: "invalid svg payload")
        }

        return okResponse(["ok": true])
    }

    private static func normalizedPID(_ value: Any?) -> pid_t? {
        guard let number = value as? NSNumber, number.intValue > 0 else {
            return nil
        }

        return pid_t(number.intValue)
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func okResponse(_ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "application/json",
                "x-clawd-server": "hey-clawd",
            ],
            body: (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        )
    }

    private static func errorResponse(statusCode: Int, message: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: [
                "Content-Type": "application/json",
                "x-clawd-server": "hey-clawd",
            ],
            body: (try? JSONSerialization.data(withJSONObject: ["error": message], options: [])) ?? Data("{}".utf8)
        )
    }

}

private enum SVGUpdate {
    case unspecified
    case explicit(String?)
    case invalid
}

private extension AppDelegate {
    static func extractSVGUpdate(from payload: [String: Any]) -> SVGUpdate {
        if payload.keys.contains("display_svg") {
            return decodeSVGField(payload["display_svg"])
        }

        if payload.keys.contains("svg") {
            return decodeSVGField(payload["svg"])
        }

        return .unspecified
    }

    static func decodeSVGField(_ value: Any?) -> SVGUpdate {
        if value is NSNull {
            return .explicit(nil)
        }

        guard let string = value as? String else {
            return .invalid
        }

        let basename = URL(fileURLWithPath: string).lastPathComponent
        return .explicit(basename.isEmpty ? nil : basename)
    }
}
