import Foundation
import CoreGraphics
import QuartzCore

protocol AnimationBinding {
    var animationName: String { get }
    var duration: TimeInterval { get }
    var timingFunction: TimingFunction { get }
    var iterationCount: AnimationIterationCount { get }
    var direction: AnimationDirection { get }
    var delay: TimeInterval { get }
    var fillMode: AnimationFillMode { get }
}

enum CAAnimationBuilder {
    static func mediaTimingFunction(from tf: TimingFunction) -> CAMediaTimingFunction {
        switch tf {
        case .easeInOut:
            return CAMediaTimingFunction(name: .easeInEaseOut)
        case .linear:
            return CAMediaTimingFunction(name: .linear)
        case .easeOut:
            return CAMediaTimingFunction(name: .easeOut)
        case .easeIn:
            return CAMediaTimingFunction(name: .easeIn)
        case .stepEnd:
            return CAMediaTimingFunction(name: .linear)
        case .cubicBezier(let x1, let y1, let x2, let y2):
            return CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
        }
    }

    static func isStepEnd(_ tf: TimingFunction) -> Bool {
        if case .stepEnd = tf {
            return true
        }
        return false
    }

    static func buildKeyframeAnimation(
        for cssProperty: String,
        keyframes: [SVGKeyframe],
        binding: any AnimationBinding,
        circleCenter: CGPoint? = nil
    ) -> CAKeyframeAnimation? {
        let property = cssProperty.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let keyPath: String
        let entries: [(NSNumber, Any)]

        switch property {
        case "transform":
            keyPath = "transform"
            guard let resolvedEntries = keyframeEntries(for: property, keyframes: keyframes, value: {
                NSValue(caTransform3D: TransformParser.parse($0))
            }) else {
                return nil
            }
            entries = resolvedEntries

        case "opacity":
            keyPath = "opacity"
            guard let resolvedEntries = keyframeEntries(for: property, keyframes: keyframes, value: {
                guard let value = Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return nil
                }
                return NSNumber(value: Float(value))
            }) else {
                return nil
            }
            entries = resolvedEntries

        case "fill":
            keyPath = "fillColor"
            let fallback = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
            guard let resolvedEntries = keyframeEntries(for: property, keyframes: keyframes, value: {
                ColorParser.parse($0) ?? fallback
            }) else {
                return nil
            }
            entries = resolvedEntries

        case "visibility":
            keyPath = "hidden"
            guard let resolvedEntries = keyframeEntries(for: property, keyframes: keyframes, value: {
                switch $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "visible":
                    return NSNumber(value: false)
                case "hidden":
                    return NSNumber(value: true)
                default:
                    return nil
                }
            }) else {
                return nil
            }
            entries = resolvedEntries

        case "stroke-width":
            keyPath = "lineWidth"
            guard let resolvedEntries = keyframeEntries(for: property, keyframes: keyframes, value: {
                guard let value = Self.parseCSSLength($0) else {
                    return nil
                }
                return NSNumber(value: value)
            }) else {
                return nil
            }
            entries = resolvedEntries

        case "r":
            guard let circleCenter else {
                return nil
            }

            keyPath = "path"
            guard let resolvedEntries = keyframeEntries(for: property, keyframes: keyframes, value: {
                guard let radius = Self.parseCSSLength($0), radius >= 0 else {
                    return nil
                }
                return circlePath(center: circleCenter, radius: CGFloat(radius))
            }) else {
                return nil
            }
            entries = resolvedEntries

        case "width":
            keyPath = "bounds.size.width"
            guard let resolvedEntries = keyframeEntries(for: property, keyframes: keyframes, value: {
                guard let value = Self.parseCSSLength($0) else {
                    return nil
                }
                return NSNumber(value: value)
            }) else {
                return nil
            }
            entries = resolvedEntries

        default:
            return nil
        }

        guard !entries.isEmpty else {
            return nil
        }

        let sorted = entries.sorted { $0.0.doubleValue < $1.0.doubleValue }
        var keyTimes = sorted.map(\.0)
        var values = sorted.map(\.1)

        // CA requires keyTimes[0]==0 and keyTimes[last]==1; pad with held values.
        if let first = keyTimes.first, first.doubleValue > 0.001 {
            keyTimes.insert(NSNumber(value: 0), at: 0)
            values.insert(values[0], at: 0)
        }
        if let last = keyTimes.last, last.doubleValue < 0.999 {
            keyTimes.append(NSNumber(value: 1))
            values.append(values[values.count - 1])
        }

        if binding.direction == .reverse || binding.direction == .alternateReverse {
            let reversedEntries = Array(zip(keyTimes, values).reversed())
            keyTimes = reversedEntries.map { NSNumber(value: 1 - $0.0.doubleValue) }
            values = reversedEntries.map { $0.1 }
        }

        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.keyTimes = keyTimes
        animation.values = values
        animation.duration = binding.duration
        animation.repeatCount = repeatCount(from: binding.iterationCount)
        animation.autoreverses = (binding.direction == .alternate || binding.direction == .alternateReverse)
        animation.fillMode = caFillMode(from: binding.fillMode)
        animation.isRemovedOnCompletion = shouldRemoveOnCompletion(binding.fillMode)

        // CSS animation-timing-function applies per-segment (between each pair of
        // keyframes), not to the overall timeline. Use timingFunctions (plural) to
        // match CSS semantics; the singular timingFunction would warp the global
        // timeline, causing later keyframes to fire earlier than expected.
        let segmentCount = max(keyTimes.count - 1, 1)
        let tf = mediaTimingFunction(from: binding.timingFunction)
        animation.timingFunctions = Array(repeating: tf, count: segmentCount)

        if binding.delay > 0 {
            animation.beginTime = CACurrentMediaTime() + binding.delay
        } else if binding.delay < 0 {
            animation.timeOffset = -binding.delay
        }

        if isStepEnd(binding.timingFunction) {
            animation.calculationMode = .discrete
        }

        return animation
    }

    static func repeatCount(from count: AnimationIterationCount) -> Float {
        switch count {
        case .infinite:
            return .infinity
        case .count(let n):
            return Float(n)
        }
    }

    static func caFillMode(from mode: AnimationFillMode) -> CAMediaTimingFillMode {
        switch mode {
        case .forwards:
            return .forwards
        case .both:
            return .both
        case .backwards:
            return .backwards
        case .none:
            return .removed
        }
    }

    static func shouldRemoveOnCompletion(_ mode: AnimationFillMode) -> Bool {
        switch mode {
        case .forwards, .both:
            return false
        case .backwards, .none:
            return true
        }
    }

    static func buildAnimation(
        from animation: SVGAnimation,
        binding: any AnimationBinding,
        circleCenter: CGPoint? = nil
    ) -> CAAnimation? {
        let properties = animatedProperties(in: animation.keyframes)
        guard !properties.isEmpty else {
            return nil
        }

        let animations = properties.compactMap {
            buildKeyframeAnimation(
                for: $0,
                keyframes: animation.keyframes,
                binding: binding,
                circleCenter: circleCenter
            )
        }

        guard !animations.isEmpty else {
            return nil
        }

        if animations.count == 1 {
            return animations[0]
        }

        for child in animations {
            child.beginTime = 0
            child.repeatCount = 0
            child.autoreverses = false
            child.fillMode = .removed
            child.isRemovedOnCompletion = true
            child.duration = binding.duration
        }

        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = binding.duration
        group.repeatCount = repeatCount(from: binding.iterationCount)
        group.fillMode = caFillMode(from: binding.fillMode)
        group.isRemovedOnCompletion = shouldRemoveOnCompletion(binding.fillMode)
        group.autoreverses = (binding.direction == .alternate || binding.direction == .alternateReverse)

        if binding.delay > 0 {
            group.beginTime = CACurrentMediaTime() + binding.delay
        } else if binding.delay < 0 {
            group.timeOffset = -binding.delay
        }

        return group
    }

    @MainActor
    static func apply(_ document: SVGDocument, to rootLayer: CALayer) {
        let resolvedBindings = resolveBindings(from: document)

        for binding in resolvedBindings {
            let layers = findLayers(matching: binding.selector, in: rootLayer)
            guard !layers.isEmpty else {
                logWarning("CAAnimationBuilder: no layer found for selector \(selectorKey(binding.selector))")
                continue
            }
            guard let animation = document.animations[binding.animationName] else {
                continue
            }

            for layer in layers {
                guard let caAnimation = buildAnimation(
                    from: animation,
                    binding: binding,
                    circleCenter: circleCenter(for: layer)
                ) else {
                    continue
                }

                applyTransformOriginIfNeeded(binding.transformOrigin, to: layer)
                if let transformBox = binding.transformBox, layer.value(forKey: "svgTransformBox") == nil {
                    layer.setValue(transformBox, forKey: "svgTransformBox")
                }
                adjustFillAnimationForLayerType(caAnimation, layer: layer)
                adjustAnchorForWidthAnimation(caAnimation, on: layer)
                layer.add(caAnimation, forKey: binding.animationName)
            }
        }

        for binding in document.inlineAnimationBindings {
            guard let layer = findLayer(withNodePath: binding.nodePath, in: rootLayer) else {
                logWarning("CAAnimationBuilder: no layer found for nodePath \(binding.nodePath)")
                continue
            }
            guard let animation = document.animations[binding.animationName] else {
                continue
            }
            guard let caAnimation = buildAnimation(
                from: animation,
                binding: binding,
                circleCenter: circleCenter(for: layer)
            ) else {
                continue
            }

            applyTransformOriginIfNeeded(binding.transformOrigin, to: layer)
            if let transformBox = binding.transformBox, layer.value(forKey: "svgTransformBox") == nil {
                layer.setValue(transformBox, forKey: "svgTransformBox")
            }
            adjustFillAnimationForLayerType(caAnimation, layer: layer)
            adjustAnchorForWidthAnimation(caAnimation, on: layer)
            layer.add(caAnimation, forKey: binding.animationName)
        }

        for binding in document.transitions {
            let layers = findLayers(matching: binding.selector, in: rootLayer)
            for layer in layers {
                storeTransition(binding, on: layer)
            }
        }

        for binding in document.inlineTransitionBindings {
            guard let layer = findLayer(withNodePath: binding.nodePath, in: rootLayer) else {
                continue
            }
            storeTransition(
                property: binding.property,
                duration: binding.duration,
                timingFunction: binding.timingFunction,
                delay: binding.delay,
                on: layer
            )
        }
    }
}

private extension CAAnimationBuilder {
    struct ResolvedBinding: AnimationBinding {
        var selector: CSSSelector
        var animationName: String
        var duration: TimeInterval
        var timingFunction: TimingFunction
        var iterationCount: AnimationIterationCount
        var direction: AnimationDirection
        var delay: TimeInterval
        var fillMode: AnimationFillMode
        var transformOrigin: SVGTransformOrigin?
        var transformBox: String?
    }

    static func animatedProperties(in keyframes: [SVGKeyframe]) -> [String] {
        var properties: [String] = []
        var seen: Set<String> = []

        for keyframe in keyframes {
            for property in keyframe.properties.keys {
                let normalized = property.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                    continue
                }
                properties.append(normalized)
            }
        }

        return properties
    }

    static func keyframeEntries(
        for property: String,
        keyframes: [SVGKeyframe],
        value transform: (String) -> Any?
    ) -> [(NSNumber, Any)]? {
        var entries: [(NSNumber, Any)] = []

        for keyframe in keyframes {
            guard let rawValue = keyframe.properties[property] else {
                continue
            }

            guard let value = transform(rawValue) else {
                return nil
            }

            for offset in keyframe.offsets {
                entries.append((NSNumber(value: Double(offset)), value))
            }
        }

        return entries
    }

    static func circlePath(center: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(
            ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ),
            transform: nil
        )
    }

    static func resolveBindings(from document: SVGDocument) -> [ResolvedBinding] {
        let styleBindingsBySelector = Dictionary(grouping: document.animationStyleBindings) {
            selectorKey($0.selector)
        }
        var result: [ResolvedBinding] = []

        for binding in document.animationBindings {
            var resolved = ResolvedBinding(
                selector: binding.selector,
                animationName: binding.animationName,
                duration: binding.duration,
                timingFunction: binding.timingFunction,
                iterationCount: binding.iterationCount,
                direction: binding.direction,
                delay: binding.delay,
                fillMode: binding.fillMode,
                transformOrigin: binding.transformOrigin,
                transformBox: binding.transformBox
            )

            for styleBinding in styleBindingsBySelector[selectorKey(binding.selector)] ?? [] {
                if let name = styleBinding.animationName {
                    resolved.animationName = name
                }
                if let duration = styleBinding.duration {
                    resolved.duration = duration
                }
                if let timingFunction = styleBinding.timingFunction {
                    resolved.timingFunction = timingFunction
                }
                if let iterationCount = styleBinding.iterationCount {
                    resolved.iterationCount = iterationCount
                }
                if let direction = styleBinding.direction {
                    resolved.direction = direction
                }
                if let delay = styleBinding.delay {
                    resolved.delay = delay
                }
                if let fillMode = styleBinding.fillMode {
                    resolved.fillMode = fillMode
                }
                if let transformOrigin = styleBinding.transformOrigin {
                    resolved.transformOrigin = transformOrigin
                }
                if let transformBox = styleBinding.transformBox {
                    resolved.transformBox = transformBox
                }
            }

            result.append(resolved)
        }

        let coveredAnimationKeys = Set(
            document.animationBindings.map {
                "\(selectorKey($0.selector))|\($0.animationName)"
            }
        )

        for styleBinding in document.animationStyleBindings {
            guard let animationName = styleBinding.animationName,
                  !animationName.isEmpty else {
                continue
            }

            let key = "\(selectorKey(styleBinding.selector))|\(animationName)"
            guard !coveredAnimationKeys.contains(key) else {
                continue
            }

            result.append(
                ResolvedBinding(
                    selector: styleBinding.selector,
                    animationName: animationName,
                    duration: styleBinding.duration ?? 0,
                    timingFunction: styleBinding.timingFunction ?? CSSParser.defaultTimingFunction,
                    iterationCount: styleBinding.iterationCount ?? .count(1),
                    direction: styleBinding.direction ?? .normal,
                    delay: styleBinding.delay ?? 0,
                    fillMode: styleBinding.fillMode ?? .none,
                    transformOrigin: styleBinding.transformOrigin,
                    transformBox: styleBinding.transformBox
                )
            )
        }

        return result
    }

    static func selectorKey(_ selector: CSSSelector) -> String {
        switch selector {
        case .className(let name):
            return ".\(name)"
        case .id(let name):
            return "#\(name)"
        }
    }

    @MainActor
    static func applyTransformOriginIfNeeded(_ origin: SVGTransformOrigin?, to layer: CALayer) {
        guard let origin else {
            return
        }
        guard layer.value(forKey: "svgTransformOrigin") == nil else {
            return
        }

        CALayerRenderer.setAnchorPoint(origin, on: layer)
        layer.setValue(serializedTransformOrigin(origin), forKey: "svgTransformOrigin")
    }

    @MainActor
    static func adjustFillAnimationForLayerType(_ animation: CAAnimation, layer: CALayer) {
        guard !(layer is CAShapeLayer) else {
            return
        }

        if let keyframe = animation as? CAKeyframeAnimation, keyframe.keyPath == "fillColor" {
            keyframe.keyPath = "backgroundColor"
            return
        }

        if let group = animation as? CAAnimationGroup {
            for child in group.animations ?? [] {
                if let keyframe = child as? CAKeyframeAnimation, keyframe.keyPath == "fillColor" {
                    keyframe.keyPath = "backgroundColor"
                }
            }
        }
    }

    @MainActor
    static func adjustAnchorForWidthAnimation(_ animation: CAAnimation, on layer: CALayer) {
        let hasWidthAnimation: Bool
        if let keyframe = animation as? CAKeyframeAnimation {
            hasWidthAnimation = keyframe.keyPath == "bounds.size.width"
        } else if let group = animation as? CAAnimationGroup {
            hasWidthAnimation = group.animations?.contains(where: {
                ($0 as? CAKeyframeAnimation)?.keyPath == "bounds.size.width"
            }) ?? false
        } else {
            hasWidthAnimation = false
        }

        guard hasWidthAnimation else {
            return
        }

        let oldAnchorPoint = layer.anchorPoint
        let bounds = layer.bounds
        layer.anchorPoint = CGPoint(x: 0, y: oldAnchorPoint.y)
        layer.position = CGPoint(
            x: layer.position.x - (oldAnchorPoint.x * bounds.width),
            y: layer.position.y
        )
    }

    @MainActor
    static func storeTransition(_ binding: SVGTransitionBinding, on layer: CALayer) {
        storeTransition(
            property: binding.property,
            duration: binding.duration,
            timingFunction: binding.timingFunction,
            delay: binding.delay,
            on: layer
        )
    }

    @MainActor
    static func storeTransition(
        property: String,
        duration: TimeInterval,
        timingFunction: TimingFunction,
        delay: TimeInterval,
        on layer: CALayer
    ) {
        var existing = layer.value(forKey: "svgTransitions") as? [[String: Any]] ?? []
        existing.append([
            "property": property,
            "duration": duration,
            "timingFunction": timingFunction,
            "delay": delay,
        ])
        layer.setValue(existing, forKey: "svgTransitions")
    }

    @MainActor
    static func findLayers(matching selector: CSSSelector, in rootLayer: CALayer) -> [CALayer] {
        var matches: [CALayer] = []
        traverseLayerTree(rootLayer) { layer in
            switch selector {
            case .className(let className):
                let classes = layer.value(forKey: "svgClasses") as? [String] ?? []
                if classes.contains(className) {
                    matches.append(layer)
                }
            case .id(let id):
                if layer.name == id {
                    matches.append(layer)
                }
            }
        }
        return matches
    }

    @MainActor
    static func findLayer(withNodePath path: String, in rootLayer: CALayer) -> CALayer? {
        var match: CALayer?
        traverseLayerTree(rootLayer) { layer in
            guard match == nil else {
                return
            }
            if (layer.value(forKey: "svgNodePath") as? String) == path {
                match = layer
            }
        }
        return match
    }

    @MainActor
    static func traverseLayerTree(_ layer: CALayer, visitor: (CALayer) -> Void) {
        visitor(layer)
        for sublayer in layer.sublayers ?? [] {
            traverseLayerTree(sublayer, visitor: visitor)
        }
    }

    @MainActor
    static func circleCenter(for layer: CALayer) -> CGPoint? {
        guard let shapeLayer = layer as? CAShapeLayer,
              let path = shapeLayer.path else {
            return nil
        }

        let bounds = path.boundingBoxOfPath
        guard !bounds.isNull, !bounds.isEmpty else {
            return nil
        }

        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    static func serializedTransformOrigin(_ origin: SVGTransformOrigin) -> String {
        "\(serializedTransformOriginComponent(origin.x)) \(serializedTransformOriginComponent(origin.y))"
    }

    static func serializedTransformOriginComponent(_ component: SVGTransformOriginComponent) -> String {
        switch component {
        case .px(let value):
            return "\(value)px"
        case .percent(let value):
            return "\(value)%"
        }
    }

    static func parseCSSLength(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("px") {
            return Double(String(trimmed.dropLast(2)))
        }
        return Double(trimmed)
    }

    static func logWarning(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
    }
}
