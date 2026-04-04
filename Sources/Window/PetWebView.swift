import AppKit
import WebKit

@MainActor
// 负责把本地 bridge.html + SVG 资源接进 WKWebView。
final class PetWebView: NSView {
    private let bridgeName = "bridge"
    private lazy var webView: WKWebView = makeWebView()
    private var pendingSVGFilename: String?
    private var isBridgeReady = false
    // 透明区域命中依赖 JS 侧的 live SVG DOM 命中检测，这里缓存最近一次结果给窗口层复用。
    private var hitTestTimer: Timer?
    private var isSamplingHitTest = false
    private var lastHitTestPoint: NSPoint?
    private var lastHitTestResult = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)

        loadBridgeDocument()
        startHitTestSampling()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadSVG(_ filename: String) {
        // bridge 页面未 ready 前先记住目标 SVG，等 JS 主动回报后再发。
        pendingSVGFilename = filename

        guard isBridgeReady else {
            return
        }

        evaluateBridgeCall("window.HeyClawdBridge.loadSVG(\(quotedJavaScriptString(filename)))")
    }

    func evaluateBridgeCall(_ script: String) {
        webView.evaluateJavaScript(script)
    }

    func shouldHandleMouse(at windowPoint: NSPoint) -> Bool {
        // 只接受和最近一次采样点足够接近的命中结果，避免吃到过期状态。
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

    private func startHitTestSampling() {
        // 不等点击发生时再查 JS，持续采样才能及时切换窗口的鼠标穿透状态。
        hitTestTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.samplePointerOpacity()
            }
        }
        RunLoop.main.add(hitTestTimer!, forMode: .common)
    }

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
        let script = "window.HeyClawdBridge.hitTestAt(\(localPoint.x), \(localPoint.y))"

        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self else {
                return
            }

            Task { @MainActor in
                self.isSamplingHitTest = false
                self.lastHitTestPoint = localPoint
                self.lastHitTestResult = (value as? NSNumber)?.boolValue ?? false
                // 指到透明区时直接让整个窗口放弃鼠标事件，事件会自然落到下层窗口。
                self.window?.ignoresMouseEvents = !self.lastHitTestResult
            }
        }
    }

    private func bundledResourcesURL() -> URL? {
        let fileManager = FileManager.default
        var candidates = [
            // folder reference 打包后通常会落在 bundle 里的 Resources/ 子目录。
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

    private func quotedJavaScriptString(_ value: String) -> String {
        // 复用 JSON 转义，避免文件名里有引号时拼 JS 字符串出错。
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        let json = String(data: data ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        return String(json.dropFirst().dropLast())
    }

    fileprivate func handleBridgeMessage(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else {
            return
        }

        if type == "bridge-ready" {
            isBridgeReady = true

            if let filename = pendingSVGFilename {
                // JS bridge 就绪后补发初始化阶段积压的 SVG 请求。
                loadSVG(filename)
            }
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
