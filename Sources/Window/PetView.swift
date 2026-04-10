import AppKit
import QuartzCore

@MainActor
final class PetView: NSView {
    private var mountedRootLayer: CALayer?
    private var mountedSVGFilename: String?
    private var eyesLayer: CALayer?
    private var bodyLayer: CALayer?
    private var shadowLayer: CALayer?
    private var switchGeneration: UInt64 = 0

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
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layerContentsRedrawPolicy = .never
        _ = eyeTracker
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        mountedRootLayer?.frame = bounds
    }

    func loadSVG(_ filename: String) {
        guard let hostLayer = layer,
              let (newRootLayer, mountedFilename) = buildSVGLayer(from: filename) else {
            return
        }

        switchGeneration &+= 1

        mountedRootLayer?.removeFromSuperlayer()

        hostLayer.addSublayer(newRootLayer)
        mountedRootLayer = newRootLayer
        mountedSVGFilename = mountedFilename
        eyesLayer = findNamedLayer("eyes-js", in: newRootLayer)
        bodyLayer = findNamedLayer("body", in: newRootLayer)
        shadowLayer = findNamedLayer("shadow", in: newRootLayer)
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

        switchGeneration &+= 1
        let generation = switchGeneration

        newRootLayer.opacity = 0
        hostLayer.addSublayer(newRootLayer)

        mountedRootLayer = newRootLayer
        mountedSVGFilename = mountedFilename
        eyesLayer = findNamedLayer("eyes-js", in: newRootLayer)
        bodyLayer = findNamedLayer("body", in: newRootLayer)
        shadowLayer = findNamedLayer("shadow", in: newRootLayer)

        let fadeDuration = 0.12

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = fadeDuration

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = fadeDuration

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak oldRoot] in
            oldRoot?.removeFromSuperlayer()
        }
        newRootLayer.add(fadeIn, forKey: "pet-switch-fade-in")
        oldRoot.add(fadeOut, forKey: "pet-switch-fade-out")
        newRootLayer.opacity = 1
        oldRoot.opacity = 0
        CATransaction.commit()

        eyeTracker.forceResend()
    }

    func playDragReaction() {
        // TODO: Phase 4.5
    }

    func playReaction(svgFilename: String) {
        // TODO: Phase 4.5
    }

    func resumeFromReaction(svgFilename: String) {
        // TODO: Phase 4.5
    }

    func setMiniLeft(_ enabled: Bool) {
        // TODO: Phase 4.6
    }

    func pauseTracking() {
        // TODO: Phase 4.3
    }

    func resumeTracking() {
        // TODO: Phase 4.3
    }

    func shouldHandleMouse(at windowPoint: NSPoint) -> Bool {
        // TODO: Phase 4.3
        false
    }

    func shouldHandleHover(at windowPoint: NSPoint) -> Bool {
        // TODO: Phase 4.3
        false
    }

    func teardown() {
        if let mountedRootLayer {
            removeAllAnimationsRecursively(from: mountedRootLayer)
            mountedRootLayer.removeFromSuperlayer()
        }

        mountedRootLayer = nil
        eyesLayer = nil
        bodyLayer = nil
        shadowLayer = nil
        eyeTracker.stop()
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
        // TODO: Phase 4.4
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
        guard let markup = svgMarkup(for: filename) else {
            print("pet svg-read-error: \(filename)")
            return nil
        }

        let document = SVGParser.parse(markup)
        let rootLayer = CALayerRenderer.build(document)
        CAAnimationBuilder.apply(document, to: rootLayer)
        rootLayer.frame = bounds
        return (rootLayer, filename)
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
}
