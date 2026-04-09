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
                guard let value = Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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
                guard let radius = Double($0.trimmingCharacters(in: .whitespacesAndNewlines)),
                      radius >= 0 else {
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
                guard let value = Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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

        var keyTimes = entries.map(\.0)
        var values = entries.map(\.1)

        if binding.direction == .reverse || binding.direction == .alternateReverse {
            let reversedEntries = Array(zip(keyTimes, values).reversed())
            keyTimes = reversedEntries.map { NSNumber(value: 1 - $0.0.doubleValue) }
            values = reversedEntries.map { $0.1 }
        }

        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.keyTimes = keyTimes
        animation.values = values
        animation.duration = binding.duration
        animation.timingFunction = mediaTimingFunction(from: binding.timingFunction)
        animation.repeatCount = repeatCount(from: binding.iterationCount)
        animation.autoreverses = (binding.direction == .alternate || binding.direction == .alternateReverse)
        animation.fillMode = caFillMode(from: binding.fillMode)
        animation.isRemovedOnCompletion = shouldRemoveOnCompletion(binding.fillMode)

        if binding.delay > 0 {
            animation.beginTime = CACurrentMediaTime() + binding.delay
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
        case .forwards, .both:
            return .forwards
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
}

private extension CAAnimationBuilder {
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
}
