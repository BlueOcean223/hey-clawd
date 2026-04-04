import AppKit
import WebKit

@MainActor
// 负责把本地 bridge.html + SVG 资源接进 WKWebView。
final class PetWebView: NSView {
    private let bridgeName = "bridge"
    private lazy var webView: WKWebView = makeWebView()
    private var pendingSVGFilename: String?
    private var isBridgeReady = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)

        loadBridgeDocument()
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

    private func bundledResourcesURL() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            // folder reference 打包后通常会落在 bundle 里的 Resources/ 子目录。
            Bundle.main.resourceURL?.appendingPathComponent("Resources", isDirectory: true),
            Bundle.main.resourceURL,
        ]

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
