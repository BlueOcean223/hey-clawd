import AppKit
import QuartzCore

/// 桌宠的 Core Animation 渲染宿主视图。
///
/// 三大职责：
/// 1. 把 SVG 文件解析、缓存（`SVGDocumentCache`）并构建成 CALayer 树挂到 host layer 上；
/// 2. 切换 SVG 时做 0.12s 交叉淡入淡出，避免硬切跳帧；
/// 3. 命中测试 + 鼠标穿透：透明像素让鼠标事件穿过，只有桌宠主体才"接收"点击/拖拽。
///
/// 眼球追踪由 `EyeTracker` 用 10Hz timer 驱动，PetView 负责把偏移转成
/// 各 layer（eyes-js / body-js / shadow-js）的视觉位移。
@MainActor
final class PetView: NSView {
    /// 拖拽时切换的统一反应 SVG。
    private static let dragReactionSVG = "clawd-react-drag.svg"
    /// 命中检测自愈定时器周期：当窗口被设为 ignoresMouseEvents=true 后，
    /// 鼠标移动事件不再投递给我们；这个定时器周期性主动询问光标位置以恢复事件。
    private static let mouseRecoveryTimerIntervalMs: Int = 200

    private var mountedRootLayer: CALayer?
    private var mountedSVGFilename: String?
    private var eyesLayer: CALayer?
    private var bodyLayer: CALayer?
    private var shadowLayer: CALayer?
    private var trackingArea: NSTrackingArea?
    private var lastHitTestPoint: NSPoint?
    private var lastHitTestResult = false
    private let mouseRecoveryTimer: DispatchSourceTimer
    private var isMouseRecoveryTimerStopped = false
    private var isMouseRecoveryTimerPaused = false
    private var isCrossfading = false
    private var crossfadeGeneration: UInt = 0

    private(set) var isTrackingPaused = false
    private(set) var isMirrored = false

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

    override init(frame frameRect: NSRect) {
        let mouseRecoveryTimer = DispatchSource.makeTimerSource(queue: .main)
        mouseRecoveryTimer.schedule(
            deadline: .now() + .milliseconds(Self.mouseRecoveryTimerIntervalMs),
            repeating: .milliseconds(Self.mouseRecoveryTimerIntervalMs)
        )
        self.mouseRecoveryTimer = mouseRecoveryTimer

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layerContentsRedrawPolicy = .never
        mouseRecoveryTimer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.recoverMouseTrackingIfNeeded()
            }
        }
        mouseRecoveryTimer.resume()
        _ = eyeTracker
        syncEyeTrackingTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let mountedRootLayer {
            applyScaling(to: mountedRootLayer)
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let newArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newArea)
        trackingArea = newArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHitTesting(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHitTesting(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        _ = event
        lastHitTestResult = false
        window?.ignoresMouseEvents = true
    }

    /// 加载 SVG 并直接挂上去，不做转场——用于首屏和"被反应动画覆盖"路径。
    func loadSVG(_ filename: String) {
        guard let hostLayer = layer,
              let (newRootLayer, mountedFilename) = buildSVGLayer(from: filename) else {
            return
        }

        removeHostSublayers(from: hostLayer)

        hostLayer.addSublayer(newRootLayer)
        mountedRootLayer = newRootLayer
        mountedSVGFilename = mountedFilename
        eyesLayer = findNamedLayer("eyes-js", in: newRootLayer)
        bodyLayer = findNamedLayer("body-js", in: newRootLayer)
        shadowLayer = findNamedLayer("shadow-js", in: newRootLayer)
        crossfadeGeneration &+= 1
        isCrossfading = false
        syncEyeTrackingTimer(forceResend: true)
    }

    /// 切换到新的 SVG，伴随 0.12s 交叉淡入淡出。
    /// 同名 SVG 直接跳过。`crossfadeGeneration` 用于让超时清理只动当次淡出对象，
    /// 避免在快速连续切换时旧的 timer 误删新挂上的 layer。
    func switchSVG(_ filename: String) {
        guard mountedRootLayer != nil else {
            loadSVG(filename)
            return
        }

        guard filename != mountedSVGFilename else {
            return
        }

        guard let hostLayer = layer,
              let oldRoot = mountedRootLayer,
              let (newRootLayer, mountedFilename) = buildSVGLayer(from: filename) else {
            return
        }

        let oldRootOpacity = oldRoot.presentation()?.opacity ?? oldRoot.opacity

        // 清理上次转场残留的孤儿图层，同时保留还没淡完的旧根层。
        removeHostSublayers(from: hostLayer, preserving: oldRoot, keepingVisibleFadingLayers: true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        oldRoot.removeAnimation(forKey: "pet-switch-fade-in")
        oldRoot.removeAnimation(forKey: "pet-switch-fade-out")
        oldRoot.opacity = oldRootOpacity
        newRootLayer.opacity = 0

        hostLayer.addSublayer(newRootLayer)

        mountedRootLayer = newRootLayer
        mountedSVGFilename = mountedFilename
        eyesLayer = findNamedLayer("eyes-js", in: newRootLayer)
        bodyLayer = findNamedLayer("body-js", in: newRootLayer)
        shadowLayer = findNamedLayer("shadow-js", in: newRootLayer)

        let fadeDuration = 0.12

        // 交叉淡入淡出期间禁止眼球追踪，避免切到 idle 时
        // 眼球瞬间跳到光标位置造成闪烁。淡入结束后再恢复。
        crossfadeGeneration &+= 1
        let fadeGeneration = crossfadeGeneration
        isCrossfading = true
        syncEyeTrackingTimer()
        CATransaction.commit()

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = fadeDuration

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = oldRootOpacity
        fadeOut.toValue = 0
        fadeOut.duration = fadeDuration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        newRootLayer.add(fadeIn, forKey: "pet-switch-fade-in")
        oldRoot.add(fadeOut, forKey: "pet-switch-fade-out")
        newRootLayer.opacity = 1
        oldRoot.opacity = 0
        CATransaction.commit()

        // 用定时清理替代 CATransaction.setCompletionBlock，
        // 后者在 layer speed=0（遮挡暂停）时不会触发。
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration + 0.05) { [weak oldRoot, weak self] in
            guard let self else { return }
            if let oldRoot {
                self.removeAllAnimationsRecursively(from: oldRoot)
                oldRoot.removeFromSuperlayer()
            }
            guard self.crossfadeGeneration == fadeGeneration else { return }
            self.isCrossfading = false
            self.syncEyeTrackingTimer(forceResend: true)
        }
    }

    func playDragReaction() {
        playReaction(svgFilename: Self.dragReactionSVG)
    }

    func playReaction(svgFilename: String) {
        loadSVG(svgFilename)
    }

    func resumeFromReaction(svgFilename: String) {
        switchSVG(svgFilename)
    }

    func setMiniLeft(_ enabled: Bool) {
        isMirrored = enabled
        guard let mountedRootLayer else {
            return
        }

        applyScaling(to: mountedRootLayer)
    }

    func pauseTracking() {
        isTrackingPaused = true
        pauseMouseRecoveryTimer()
        syncEyeTrackingTimer()
        lastHitTestResult = false
    }

    func resumeTracking() {
        isTrackingPaused = false
        resumeMouseRecoveryTimer()
        syncEyeTrackingTimer(forceResend: true)
    }

    /// 透明 SVG 上判断点击是否落在像素上。
    /// `lastHitTestPoint` 配合 ±2pt 容差防止 mouseMoved 与 mouseDown 之间的微小偏差导致漏判。
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

    func shouldHandleHover(at windowPoint: NSPoint) -> Bool {
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

        let hoverTolerance: CGFloat = 12
        let dx = abs(lastHitTestPoint.x - localPoint.x)
        let dy = abs(lastHitTestPoint.y - localPoint.y)
        guard dx <= hoverTolerance, dy <= hoverTolerance else {
            return false
        }

        return lastHitTestResult
    }

    func teardown() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        self.trackingArea = nil

        if let hostLayer = layer {
            for sublayer in hostLayer.sublayers ?? [] {
                sublayer.removeAllAnimations()
                sublayer.removeFromSuperlayer()
            }
        }

        mountedRootLayer = nil
        eyesLayer = nil
        bodyLayer = nil
        shadowLayer = nil
        eyeTracker.stop()
        stopMouseRecoveryTimer()
        mountedSVGFilename = nil
    }

    /// 仅在指定的 idle 类 SVG 上启用眼球追踪：
    /// 一是其它动画自带眼球关键帧会冲突，二是 working/error 等表演型动画追眼会显得诡异。
    private var shouldTrackEyes: Bool {
        guard !isTrackingPaused, !isCrossfading else {
            return false
        }

        return mountedSVGFilename == "clawd-idle-follow.svg" || mountedSVGFilename == "clawd-mini-idle.svg"
    }

    private func syncEyeTrackingTimer(forceResend: Bool = false) {
        if forceResend {
            eyeTracker.forceResend()
        }

        if shouldTrackEyes {
            eyeTracker.resume()
        } else {
            eyeTracker.pause()
        }
    }

    private var eyeScreenCenter: NSPoint? {
        guard let window else {
            return nil
        }

        // 镜像时眼球中心也要跟着翻转到对称位置。
        let xRatio: CGFloat = isMirrored ? (1 - 22.0 / 45.0) : (22.0 / 45.0)
        return NSPoint(
            x: window.frame.minX + (window.frame.width * xRatio),
            y: window.frame.minY + (window.frame.height * 34.0 / 45.0)
        )
    }

    /// 把 EyeTracker 算出的偏移翻译成 layer transform：
    /// body / shadow 用更小的乘数跟随，制造视差感而非整体平移。
    /// 镜像（mini 模式贴左侧）时 X 取反，让眼睛朝向同一边。
    private func applyEyeMove(dx: CGFloat, dy: CGFloat) {
        guard let eyesLayer else {
            return
        }

        let (transitionDuration, transitionTimingFunction) = transitionParams(for: eyesLayer, property: "transform")
        let effectiveDx = isMirrored ? -dx : dx
        let effectiveDy = -dy

        CATransaction.begin()
        CATransaction.setAnimationDuration(transitionDuration)
        CATransaction.setAnimationTimingFunction(transitionTimingFunction)
        eyesLayer.transform = CATransform3DMakeTranslation(effectiveDx, effectiveDy, 0)
        bodyLayer?.transform = CATransform3DMakeTranslation(effectiveDx * 0.3, effectiveDy * 0.3, 0)
        shadowLayer?.transform = CATransform3DMakeTranslation(effectiveDx * 0.15, effectiveDy * 0.15, 0)
        CATransaction.commit()
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

    /// 从 bundle 读取 SVG 文件原文，供 SVGParser 解析后构建 CALayer 树。
    private func svgMarkup(for filename: String) -> String? {
        guard let resourcesURL = bundledResourcesURL() else {
            return nil
        }

        let svgURL = resourcesURL
            .appendingPathComponent("svg", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)

        return try? String(contentsOf: svgURL, encoding: .utf8)
    }

    private func buildSVGLayer(from filename: String) -> (CALayer, String)? {
        guard let document = ensureSVGDocumentCached(for: filename) else {
            return nil
        }

        let rootLayer = autoreleasepool { CALayerRenderer.build(document) }
        CAAnimationBuilder.apply(document, to: rootLayer)
        applyScaling(to: rootLayer)
        return (rootLayer, filename)
    }

    private func ensureSVGDocumentCached(for filename: String) -> SVGDocument? {
        if let cached = SVGDocumentCache.shared.get(filename) {
            return cached
        }

        guard let markup = svgMarkup(for: filename) else {
            print("pet svg-read-error: \(filename)")
            return nil
        }

        // XMLParser 产生大量临时 ObjC 对象，显式 autoreleasepool 确保解析完立即释放。
        let parsed = autoreleasepool { SVGParser.parse(markup) }
        SVGDocumentCache.shared.set(filename, parsed)
        return parsed
    }

    /// Scale the SVG root layer from its native bounds (e.g. 45x45) to fill the view,
    /// incorporating the horizontal flip when `isMirrored` is true.
    private func applyScaling(to rootLayer: CALayer) {
        let svgBounds = rootLayer.bounds
        guard svgBounds.width > 0, svgBounds.height > 0 else {
            return
        }

        let scaleX = bounds.width / svgBounds.width
        let scaleY = bounds.height / svgBounds.height
        rootLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

        var transform = CATransform3DMakeScale(scaleX, scaleY, 1)
        if isMirrored {
            transform = CATransform3DScale(transform, -1, 1, 1)
        }
        rootLayer.transform = transform
    }

    private func findNamedLayer(_ name: String, in layer: CALayer) -> CALayer? {
        if layer.name == name {
            return layer
        }

        for sublayer in layer.sublayers ?? [] {
            if let namedLayer = findNamedLayer(name, in: sublayer) {
                return namedLayer
            }
        }

        return nil
    }

    private func removeAllAnimationsRecursively(from layer: CALayer) {
        layer.removeAllAnimations()

        for sublayer in layer.sublayers ?? [] {
            removeAllAnimationsRecursively(from: sublayer)
        }
    }

    private func removeHostSublayers(
        from hostLayer: CALayer,
        preserving preservedLayer: CALayer? = nil,
        keepingVisibleFadingLayers: Bool = false
    ) {
        for sublayer in hostLayer.sublayers ?? [] where sublayer !== preservedLayer {
            if keepingVisibleFadingLayers,
               isVisibleFadingLayer(sublayer) {
                continue
            }

            removeAllAnimationsRecursively(from: sublayer)
            sublayer.removeFromSuperlayer()
        }
    }

    private func isVisibleFadingLayer(_ layer: CALayer) -> Bool {
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        guard opacity > 0.01 else {
            return false
        }

        return layer.animation(forKey: "pet-switch-fade-out") != nil ||
            layer.animation(forKey: "pet-switch-fade-in") != nil
    }

    private func updateHitTesting(with event: NSEvent) {
        guard !isTrackingPaused else {
            return
        }

        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint) else {
            return
        }

        let hit = performHitTest(at: localPoint)
        lastHitTestPoint = localPoint
        lastHitTestResult = hit
        window?.ignoresMouseEvents = !hit
    }

    /// 当 ignoresMouseEvents 为 true 时系统不再投递 mouseMoved；
    /// 周期性主动用 NSEvent.mouseLocation 检查光标是否落在像素上，恢复事件投递。
    private func recoverMouseTrackingIfNeeded() {
        guard let window, window.ignoresMouseEvents, !isTrackingPaused else {
            return
        }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        guard bounds.contains(localPoint) else {
            return
        }

        let hit = performHitTest(at: localPoint)
        guard hit else {
            return
        }

        window.ignoresMouseEvents = false
        lastHitTestPoint = localPoint
        lastHitTestResult = true
    }

    private func performHitTest(at localPoint: NSPoint) -> Bool {
        guard let mountedRootLayer, let hostLayer = layer else {
            return false
        }

        let layerPoint = mountedRootLayer.convert(localPoint, from: hostLayer)
        return CALayerRenderer.hitTest(point: layerPoint, in: mountedRootLayer)
    }

    private func transitionParams(for layer: CALayer, property: String) -> (TimeInterval, CAMediaTimingFunction) {
        let defaultTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let transitions = layer.value(forKey: "svgTransitions") as? [[String: Any]] ?? []

        guard let transition = transitions.first(where: { ($0["property"] as? String) == property }) else {
            return (0.2, defaultTimingFunction)
        }

        let duration = transition["duration"] as? TimeInterval ?? 0.2
        let timingFunction = mediaTimingFunction(from: transition["timingFunction"]) ?? defaultTimingFunction
        return (duration, timingFunction)
    }

    private func mediaTimingFunction(from rawValue: Any?) -> CAMediaTimingFunction? {
        if let timingFunction = rawValue as? TimingFunction {
            return CAAnimationBuilder.mediaTimingFunction(from: timingFunction)
        }

        if let name = rawValue as? String,
           let timingFunction = timingFunction(from: name) {
            return CAAnimationBuilder.mediaTimingFunction(from: timingFunction)
        }

        return rawValue as? CAMediaTimingFunction
    }

    private func timingFunction(from rawValue: String) -> TimingFunction? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch trimmed {
        case "ease-in-out":
            return .easeInOut
        case "linear":
            return .linear
        case "ease-out":
            return .easeOut
        case "ease-in":
            return .easeIn
        case "step-end":
            return .stepEnd
        case "ease":
            return .cubicBezier(0.25, 0.1, 0.25, 1)
        default:
            guard trimmed.hasPrefix("cubic-bezier("), trimmed.hasSuffix(")") else {
                return nil
            }

            let arguments = String(trimmed.dropFirst("cubic-bezier(".count).dropLast())
            let values = arguments
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap(Double.init)

            guard values.count == 4 else {
                return nil
            }

            return .cubicBezier(
                CGFloat(values[0]),
                CGFloat(values[1]),
                CGFloat(values[2]),
                CGFloat(values[3])
            )
        }
    }

    private func pauseMouseRecoveryTimer() {
        guard !isMouseRecoveryTimerStopped, !isMouseRecoveryTimerPaused else {
            return
        }

        isMouseRecoveryTimerPaused = true
        mouseRecoveryTimer.suspend()
    }

    private func resumeMouseRecoveryTimer() {
        guard !isMouseRecoveryTimerStopped, isMouseRecoveryTimerPaused else {
            return
        }

        isMouseRecoveryTimerPaused = false
        mouseRecoveryTimer.resume()
    }

    private func stopMouseRecoveryTimer() {
        guard !isMouseRecoveryTimerStopped else {
            return
        }

        if isMouseRecoveryTimerPaused {
            mouseRecoveryTimer.resume()
            isMouseRecoveryTimerPaused = false
        }

        isMouseRecoveryTimerStopped = true
        mouseRecoveryTimer.setEventHandler {}
        mouseRecoveryTimer.cancel()
    }
}
