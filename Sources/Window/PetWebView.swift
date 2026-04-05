import AppKit
import WebKit

/// WKWebView 封装层：加载 bridge.html，将 SVG 内联挂载到 DOM，
/// 并以 30Hz 轮询鼠标位置做命中检测，驱动窗口的 ignoresMouseEvents 切换。
@MainActor
final class PetWebView: NSView {
    private let bridgeName = "bridge"
    private lazy var webView: WKWebView = makeWebView()
    private lazy var eyeTracker = EyeTracker(
        isEnabled: { [weak self] in
            self?.shouldTrackEyes ?? false
        },
        eyeCenterProvider: { [weak self] in
            self?.eyeScreenCenter
        },
        onOffsetChange: { [weak self] dx, dy in
            self?.applyEyeMove(dx: dx, dy: dy)
        }
    )
    /// bridge 页面加载前积压的 SVG 文件名，bridge-ready 后补发。
    private var pendingSVGFilename: String?
    private var isBridgeReady = false
    /// 只在 bridge.js 确认 svg-loaded 后更新，表示当前屏幕上真正显示的文件。
    private var mountedSVGFilename: String?

    // ── 命中检测状态 ──
    // 30Hz Timer 持续采样鼠标位置，通过 JS hitTestAt 判断是否落在 SVG 实体像素上，
    // 结果缓存在这里供 PetWindow.sendEvent 复用。
    private var hitTestTimer: Timer?
    /// 防止上一次 evaluateJavaScript 尚未回调时重复发起。
    private var isSamplingHitTest = false
    private var lastHitTestPoint: NSPoint?
    private var lastHitTestResult = false
    /// 去重日志：只在消息内容变化时打印，避免 30Hz 刷屏。
    private var lastHitTestErrorMessage: String?
    private var lastNonBooleanHitTestDescription: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)

        loadBridgeDocument()
        startHitTestSampling()
        _ = eyeTracker
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 从 bundle 读取 SVG 文件内容，通过 JS bridge 内联挂载到 DOM。
    /// bridge 未就绪时暂存文件名，bridge-ready 回调后自动补发。
    func loadSVG(_ filename: String) {
        pendingSVGFilename = filename

        guard isBridgeReady else {
            return
        }

        guard let markup = svgMarkup(for: filename) else {
            print("pet svg-read-error: \(filename)")
            return
        }

        evaluateBridgeCall(
            "window.HeyClawdBridge.mountSVG(\(quotedJavaScriptString(filename)), \(quotedJavaScriptString(markup)))"
        )
    }

    /// 状态机回调入口：将 SVG 文件名转为 bundle 读取 + JS mountSVG 调用。
    /// 同文件名重复调用会被 bridge.js 侧去重，Swift 侧无需额外判断。
    func switchSVG(_ filename: String) {
        loadSVG(filename)
    }

    func evaluateBridgeCall(_ script: String) {
        webView.evaluateJavaScript(script)
    }

    /// 3.1 只在 idle-follow / mini-idle 上启用眼球追踪。
    /// 其他动画即使也带 eyes-js，也先保持原始美术动作，不叠加实时偏移。
    private var shouldTrackEyes: Bool {
        guard isBridgeReady else {
            return false
        }

        return mountedSVGFilename == "clawd-idle-follow.svg" || mountedSVGFilename == "clawd-mini-idle.svg"
    }

    /// 原版眼球中心不是窗口正中，而是按美术构图落在角色脸部。
    /// 这里直接沿用 22/45、34/45 这组比例，避免窗口缩放后追踪点漂掉。
    private var eyeScreenCenter: NSPoint? {
        guard let window else {
            return nil
        }

        return NSPoint(
            x: window.frame.minX + (window.frame.width * 22.0 / 45.0),
            y: window.frame.minY + (window.frame.height * 34.0 / 45.0)
        )
    }

    private func applyEyeMove(dx: CGFloat, dy: CGFloat) {
        guard isBridgeReady else {
            return
        }

        evaluateBridgeCall("window.HeyClawdBridge.applyEyeMove(\(dx), \(dy))")
    }

    /// PetWindow.sendEvent 调用：当前点击位置是否命中桌宠实体？
    /// 比对最近一次 30Hz 采样结果，容差 2px 内视为有效。
    func shouldHandleMouse(at windowPoint: NSPoint) -> Bool {
        guard window != nil else {
            return false
        }

        let localPoint = convert(windowPoint, from: nil)
        guard bounds.contains(localPoint) else {
            return false
        }

        guard let lastHitTestPoint else {
            return false
        }

        let dx = abs(lastHitTestPoint.x - localPoint.x)
        let dy = abs(lastHitTestPoint.y - localPoint.y)
        guard dx <= 2, dy <= 2 else {
            return false
        }

        return lastHitTestResult
    }

    private func makeWebView() -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(ScriptMessageProxy(owner: self), name: bridgeName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController

        let view = WKWebView(frame: .zero, configuration: configuration)
        // AppKit 没公开透明背景开关，只能走 KVC。
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self

        if let scrollView = view.enclosingScrollView {
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
        }

        return view
    }

    private func loadBridgeDocument() {
        guard
            let resourcesURL = bundledResourcesURL(),
            let bridgeURL = bridgeDocumentURL(in: resourcesURL)
        else {
            assertionFailure("Missing Resources/web/bridge.html in app bundle")
            return
        }

        webView.loadFileURL(bridgeURL, allowingReadAccessTo: resourcesURL)
    }

    /// 启动 30Hz 命中检测轮询。
    /// 不能等点击时才查——必须提前切换 ignoresMouseEvents，否则事件根本到不了窗口。
    private func startHitTestSampling() {
        hitTestTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.samplePointerOpacity()
            }
        }
        RunLoop.main.add(hitTestTimer!, forMode: .common)
    }

    /// 单次采样：读取鼠标位置 → 翻转 Y 轴 → 调 JS hitTestAt → 更新 ignoresMouseEvents。
    private func samplePointerOpacity() {
        guard
            isBridgeReady,
            !isSamplingHitTest,
            let window
        else {
            return
        }

        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint) else {
            lastHitTestPoint = nil
            lastHitTestResult = false
            return
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        guard bounds.contains(localPoint) else {
            lastHitTestPoint = nil
            lastHitTestResult = false
            return
        }

        isSamplingHitTest = true
        // AppKit Y 轴向上（底部=0），CSS Y 轴向下（顶部=0），必须翻转。
        let flippedY = bounds.height - localPoint.y
        let script = "window.HeyClawdBridge.hitTestAt(\(localPoint.x), \(flippedY))"

        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else {
                return
            }

            Task { @MainActor in
                self.isSamplingHitTest = false

                if let error {
                    let message = error.localizedDescription
                    if self.lastHitTestErrorMessage != message {
                        print("pet hit-test error: \(message)")
                        self.lastHitTestErrorMessage = message
                    }
                    // JS 执行失败，安全回退到穿透。
                    self.lastHitTestPoint = localPoint
                    self.lastHitTestResult = false
                    self.window?.ignoresMouseEvents = true
                    return
                }

                self.lastHitTestErrorMessage = nil
                guard let hitResult = value as? NSNumber else {
                    let description = String(describing: value)
                    if self.lastNonBooleanHitTestDescription != description {
                        print("pet hit-test returned non-bool: \(description)")
                        self.lastNonBooleanHitTestDescription = description
                    }
                    // null（SVG 未加载）或其他非布尔值，默认穿透。
                    self.lastHitTestPoint = localPoint
                    self.lastHitTestResult = false
                    self.window?.ignoresMouseEvents = true
                    return
                }

                self.lastNonBooleanHitTestDescription = nil
                let nextHitResult = hitResult.boolValue
                self.lastHitTestPoint = localPoint
                self.lastHitTestResult = nextHitResult
                // 指到透明区时直接让整个窗口放弃鼠标事件，事件会自然落到下层窗口。
                self.window?.ignoresMouseEvents = !nextHitResult
            }
        }
    }

    /// 定位 app bundle 内的 Resources/ 目录。
    /// Xcode folder reference 打包和 SPM swift build 的路径不同，逐一尝试。
    private func bundledResourcesURL() -> URL? {
        let fileManager = FileManager.default
        var candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Resources", isDirectory: true),
            Bundle.main.resourceURL,
        ]

#if SWIFT_PACKAGE
        candidates.insert(Bundle.module.resourceURL?.appendingPathComponent("Resources", isDirectory: true), at: 0)
        candidates.insert(Bundle.module.resourceURL, at: 1)
#endif

        for candidate in candidates.compactMap({ $0 }) {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }

        return nil
    }

    private func bridgeDocumentURL(in resourcesURL: URL) -> URL? {
        let bridgeURL = resourcesURL
            .appendingPathComponent("web", isDirectory: true)
            .appendingPathComponent("bridge.html", isDirectory: false)

        return FileManager.default.fileExists(atPath: bridgeURL.path) ? bridgeURL : nil
    }

    /// 从 bundle 读取 SVG 文件原文，供 mountSVG 通过 JS 内联到 DOM。
    private func svgMarkup(for filename: String) -> String? {
        guard let resourcesURL = bundledResourcesURL() else {
            return nil
        }

        let svgURL = resourcesURL
            .appendingPathComponent("svg", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)

        return try? String(contentsOf: svgURL, encoding: .utf8)
    }

    private func quotedJavaScriptString(_ value: String) -> String {
        // 复用 JSON 转义，避免文件名里有引号时拼 JS 字符串出错。
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        let json = String(data: data ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        return String(json.dropFirst().dropLast())
    }

    /// 处理 JS → Swift 消息：bridge-ready / svg-loaded / svg-error。
    fileprivate func handleBridgeMessage(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else {
            return
        }

        if type == "bridge-ready" {
            isBridgeReady = true
            mountedSVGFilename = nil

            if let filename = pendingSVGFilename {
                // JS bridge 就绪后补发初始化阶段积压的 SVG 请求。
                loadSVG(filename)
            }
        } else if type == "svg-loaded" {
            mountedSVGFilename = payload["filename"] as? String
            // 新 SVG 刚挂上去时 transform 还是初始值，下一帧强制补一次眼球位置。
            eyeTracker.forceResend()
        } else if type == "svg-error" {
            let filename = payload["filename"] as? String ?? "unknown"
            let message = payload["message"] as? String ?? "unknown"
            print("pet svg-error: \(filename) (\(message))")
        }
    }
}

extension PetWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面重载后把滚动条和背景再压一遍，避免 WebKit 恢复默认值。
        if let scrollView = webView.enclosingScrollView {
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("pet webview didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("pet webview didFailProvisionalNavigation: \(error.localizedDescription)")
    }

    /// WebContent 进程崩溃后重置全部状态并重新加载 bridge。
    /// pendingSVGFilename 不清——bridge-ready 回调会自动补发最后一次 SVG。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("pet webview content process terminated")
        isBridgeReady = false
        mountedSVGFilename = nil
        lastHitTestPoint = nil
        lastHitTestResult = false
        window?.ignoresMouseEvents = true
        loadBridgeDocument()
    }
}

private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: PetWebView?

    init(owner: PetWebView) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            let payload = message.body as? [String: Any]
        else {
            return
        }

        // WebKit 回调不保证和视图同 actor，转回主线程统一处理。
        Task { @MainActor [weak owner] in
            owner?.handleBridgeMessage(payload)
        }
    }
}
