import AppKit
import QuartzCore

@MainActor
final class PetView: NSView {
    private static let dragReactionSVG = "clawd-react-drag.svg"
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
            Task { @MainActor [weak self] in
                self?.recoverMouseTrackingIfNeeded()
            }
        }
        mouseRecoveryTimer.resume()
        _ = eyeTracker
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

    func loadSVG(_ filename: String) {
        guard let hostLayer = layer,
              let (newRootLayer, mountedFilename) = buildSVGLayer(from: filename) else {
            return
        }

        mountedRootLayer?.removeFromSuperlayer()

        hostLayer.addSublayer(newRootLayer)
        mountedRootLayer = newRootLayer
        mountedSVGFilename = mountedFilename
        eyesLayer = findNamedLayer("eyes-js", in: newRootLayer)
        bodyLayer = findNamedLayer("body-js", in: newRootLayer)
        shadowLayer = findNamedLayer("shadow-js", in: newRootLayer)
        eyeTracker.forceResend()
    }

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

        // 先清理上次转场残留的孤儿图层。
        // 当窗口被遮挡时 rootLayer.speed=0，CATransaction completionBlock 不会触发，
        // 旧图层树就会一直挂着，造成内存持续增长。
        for sublayer in hostLayer.sublayers ?? [] where sublayer !== oldRoot {
            removeAllAnimationsRecursively(from: sublayer)
            sublayer.removeFromSuperlayer()
        }

        newRootLayer.opacity = 0

        hostLayer.addSublayer(newRootLayer)

        mountedRootLayer = newRootLayer
        mountedSVGFilename = mountedFilename
        eyesLayer = findNamedLayer("eyes-js", in: newRootLayer)
        bodyLayer = findNamedLayer("body-js", in: newRootLayer)
        shadowLayer = findNamedLayer("shadow-js", in: newRootLayer)

        let fadeDuration = 0.12

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = fadeDuration

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = oldRoot.presentation()?.opacity ?? oldRoot.opacity
        fadeOut.toValue = 0
        fadeOut.duration = fadeDuration

        CATransaction.begin()
        newRootLayer.add(fadeIn, forKey: "pet-switch-fade-in")
        oldRoot.add(fadeOut, forKey: "pet-switch-fade-out")
        newRootLayer.opacity = 1
        oldRoot.opacity = 0
        CATransaction.commit()

        // 用定时清理替代 CATransaction.setCompletionBlock，
        // 后者在 layer speed=0（遮挡暂停）时不会触发。
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration + 0.05) { [weak oldRoot, weak self] in
            guard let oldRoot else { return }
            self?.removeAllAnimationsRecursively(from: oldRoot)
            oldRoot.removeFromSuperlayer()
        }

        eyeTracker.forceResend()
    }

    func playDragReaction() {
        playReaction(svgFilename: Self.dragReactionSVG)
    }

    func prepareDragReaction() {
        _ = ensureSVGDocumentCached(for: Self.dragReactionSVG)
    }

    func playReaction(svgFilename: String) {
        loadSVG(svgFilename)
    }

    func resumeFromReaction(svgFilename: String) {
        switchSVG(svgFilename)
        prepareDragReaction()
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
        eyeTracker.pause()
        lastHitTestResult = false
    }

    func resumeTracking() {
        isTrackingPaused = false
        resumeMouseRecoveryTimer()
        eyeTracker.resume()
    }

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

    private var shouldTrackEyes: Bool {
        guard !isTrackingPaused else {
            return false
        }

        return mountedSVGFilename == "clawd-idle-follow.svg" || mountedSVGFilename == "clawd-mini-idle.svg"
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

        let rootLayer = CALayerRenderer.build(document)
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

        let parsed = SVGParser.parse(markup)
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
