import Foundation
import CoreGraphics
import QuartzCore
import XCTest
@testable import HeyClawdApp

@MainActor
final class CAAnimationBuilderTests: XCTestCase {
    private static var projectRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    private struct TestBinding: AnimationBinding {
        var animationName: String = "test"
        var duration: TimeInterval = 1
        var timingFunction: TimingFunction = .linear
        var iterationCount: AnimationIterationCount = .count(1)
        var direction: AnimationDirection = .normal
        var delay: TimeInterval = 0
        var fillMode: AnimationFillMode = .none
    }

    private func loadSVG(_ name: String) throws -> String {
        let path = Self.projectRoot + "/Resources/svg/\(name).svg"
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    @MainActor
    func testParseScaleXY() {
        let transform = TransformParser.parse("scale(1.02, 0.98)")

        XCTAssertEqual(transform.m11, 1.02, accuracy: 0.0001)
        XCTAssertEqual(transform.m22, 0.98, accuracy: 0.0001)
    }

    @MainActor
    func testParseCompoundScaleTranslate() {
        let transform = TransformParser.parse("scale(1.02, 0.98) translate(0, 0.5px)")

        XCTAssertFalse(CATransform3DIsIdentity(transform))
        XCTAssertEqual(transform.m42, 0.49, accuracy: 0.01)
    }

    @MainActor
    func testParseRotate() {
        let transform = TransformParser.parse("rotate(5deg)")

        XCTAssertEqual(transform.m11, cos(5 * .pi / 180), accuracy: 0.0001)
        XCTAssertEqual(transform.m12, sin(5 * .pi / 180), accuracy: 0.0001)
    }

    @MainActor
    func testParseNone() {
        let transform = TransformParser.parse("none")

        XCTAssertTrue(CATransform3DIsIdentity(transform))
    }

    @MainActor
    func testParseEmpty() {
        let transform = TransformParser.parse("")

        XCTAssertTrue(CATransform3DIsIdentity(transform))
    }

    @MainActor
    func testParseSVGRotateWithCenter() {
        let transform = TransformParser.parse("rotate(-12, 7.5, 15)")
        let center = CGPoint(x: 7.5, y: 15)
        let transformedCenter = applyTransform(transform, to: center)

        XCTAssertEqual(transformedCenter.x, center.x, accuracy: 0.0001)
        XCTAssertEqual(transformedCenter.y, center.y, accuracy: 0.0001)
    }

    @MainActor
    func testParseTranslateNoUnits() {
        let transform = TransformParser.parse("translate(7.5, 15)")
        let transformedPoint = applyTransform(transform, to: .zero)

        XCTAssertEqual(transformedPoint.x, 7.5, accuracy: 0.0001)
        XCTAssertEqual(transformedPoint.y, 15, accuracy: 0.0001)
    }

    @MainActor
    func testParseScaleUniform() {
        let transform = TransformParser.parse("scale(2)")

        XCTAssertEqual(transform.m11, 2, accuracy: 0.0001)
        XCTAssertEqual(transform.m22, 2, accuracy: 0.0001)
    }

    @MainActor
    func testParseScaleY() {
        let transform = TransformParser.parse("scaleY(0.1)")

        XCTAssertEqual(transform.m11, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.m22, 0.1, accuracy: 0.0001)
    }

    @MainActor
    func testParseScaleX() {
        let transform = TransformParser.parse("scaleX(1.05)")

        XCTAssertEqual(transform.m11, 1.05, accuracy: 0.0001)
        XCTAssertEqual(transform.m22, 1, accuracy: 0.0001)
    }

    @MainActor
    func testMediaTimingFunctionMappings() {
        let timingFunctions: [TimingFunction] = [
            .easeInOut,
            .linear,
            .easeOut,
            .easeIn,
            .stepEnd,
            .cubicBezier(0.4, 0, 0.2, 1),
        ]

        for timingFunction in timingFunctions {
            XCTAssertNotNil(CAAnimationBuilder.mediaTimingFunction(from: timingFunction))
        }
    }

    @MainActor
    func testStepEndDetection() {
        XCTAssertTrue(CAAnimationBuilder.isStepEnd(.stepEnd))
        XCTAssertFalse(CAAnimationBuilder.isStepEnd(.linear))
    }

    @MainActor
    func testBuildBreatheTransformAnimation() throws {
        let document = SVGParser.parse(
            """
            <svg viewBox="0 0 15 16" xmlns="http://www.w3.org/2000/svg">
              <defs>
                <style>
                  @keyframes breathe {
                    0%, 100% { transform: scale(1, 1) translate(0, 0); }
                    50%      { transform: scale(1.02, 0.98) translate(0, 0.5px); }
                  }
                </style>
              </defs>
            </svg>
            """
        )
        let animation = try XCTUnwrap(document.animations["breathe"])
        let binding = TestBinding(
            animationName: "breathe",
            duration: 3.2,
            timingFunction: .easeInOut,
            iterationCount: .infinite
        )

        let keyframeAnimation = try XCTUnwrap(
            CAAnimationBuilder.buildKeyframeAnimation(
                for: "transform",
                keyframes: animation.keyframes,
                binding: binding
            )
        )

        XCTAssertEqual(keyframeAnimation.keyTimes?.count, 3)
        XCTAssertEqual(keyframeAnimation.values?.count, 3)
        XCTAssertEqual(keyframeAnimation.duration, 3.2, accuracy: 0.0001)
        XCTAssertEqual(keyframeAnimation.repeatCount, .infinity)
    }

    @MainActor
    func testBuildOpacityAnimation() throws {
        let animation = SVGAnimation(
            name: "fade",
            keyframes: [
                SVGKeyframe(offsets: [0], properties: ["opacity": "1"]),
                SVGKeyframe(offsets: [0.5], properties: ["opacity": "0.4"]),
                SVGKeyframe(offsets: [1], properties: ["opacity": "1"]),
            ]
        )
        let binding = TestBinding(animationName: "fade", duration: 2)

        let keyframeAnimation = try XCTUnwrap(
            CAAnimationBuilder.buildKeyframeAnimation(
                for: "opacity",
                keyframes: animation.keyframes,
                binding: binding
            )
        )

        XCTAssertEqual(keyframeAnimation.keyTimes?.count, 3)
        XCTAssertEqual(keyframeAnimation.values?.count, 3)
    }

    @MainActor
    func testBuildAnimationMultiPropertyCreatesGroup() throws {
        let animation = SVGAnimation(
            name: "combo",
            keyframes: [
                SVGKeyframe(offsets: [0], properties: ["transform": "scale(1)", "opacity": "1"]),
                SVGKeyframe(offsets: [1], properties: ["transform": "scale(1.02)", "opacity": "0.8"]),
            ]
        )

        let builtAnimation = try XCTUnwrap(
            CAAnimationBuilder.buildAnimation(
                from: animation,
                binding: TestBinding(animationName: "combo", duration: 2)
            ) as? CAAnimationGroup
        )

        XCTAssertEqual(builtAnimation.animations?.count, 2)
    }

    @MainActor
    func testBuildAnimationSinglePropertyReturnsKeyframeAnimation() throws {
        let animation = SVGAnimation(
            name: "solo",
            keyframes: [
                SVGKeyframe(offsets: [0], properties: ["transform": "scale(1)"]),
                SVGKeyframe(offsets: [1], properties: ["transform": "scale(1.02)"]),
            ]
        )

        let builtAnimation = try XCTUnwrap(
            CAAnimationBuilder.buildAnimation(
                from: animation,
                binding: TestBinding(animationName: "solo", duration: 2)
            )
        )

        XCTAssertTrue(builtAnimation is CAKeyframeAnimation)
        XCTAssertFalse(builtAnimation is CAAnimationGroup)
    }

    @MainActor
    func testGroupDurationMatchesBinding() throws {
        let animation = SVGAnimation(
            name: "combo",
            keyframes: [
                SVGKeyframe(offsets: [0], properties: ["transform": "scale(1)", "opacity": "1"]),
                SVGKeyframe(offsets: [1], properties: ["transform": "scale(1.02)", "opacity": "0.8"]),
            ]
        )
        let binding = TestBinding(animationName: "combo", duration: 3.2)

        let group = try XCTUnwrap(
            CAAnimationBuilder.buildAnimation(from: animation, binding: binding) as? CAAnimationGroup
        )

        XCTAssertEqual(group.duration, 3.2, accuracy: 0.0001)
    }

    @MainActor
    func testGroupRepeatCountInfinite() throws {
        let animation = SVGAnimation(
            name: "combo",
            keyframes: [
                SVGKeyframe(offsets: [0], properties: ["transform": "scale(1)", "opacity": "1"]),
                SVGKeyframe(offsets: [1], properties: ["transform": "scale(1.02)", "opacity": "0.8"]),
            ]
        )
        let binding = TestBinding(animationName: "combo", duration: 3.2, iterationCount: .infinite)

        let group = try XCTUnwrap(
            CAAnimationBuilder.buildAnimation(from: animation, binding: binding) as? CAAnimationGroup
        )

        XCTAssertEqual(group.repeatCount, .infinity)
    }

    @MainActor
    func testApplyMountsBreathAnimationOnIdleFollowSVG() throws {
        let svg = try loadSVG("clawd-idle-follow")
        let document = SVGParser.parse(svg)
        let rootLayer = CALayerRenderer.build(document)

        CAAnimationBuilder.apply(document, to: rootLayer)

        let layer = try XCTUnwrap(findLayer(withClass: "breathe-anim", in: rootLayer))
        XCTAssertNotNil(layer.animation(forKey: "breathe"))
    }

    @MainActor
    func testApplyMountsEyeBlinkAnimation() throws {
        let svg = try loadSVG("clawd-idle-follow")
        let document = SVGParser.parse(svg)
        let rootLayer = CALayerRenderer.build(document)

        CAAnimationBuilder.apply(document, to: rootLayer)

        let layer = try XCTUnwrap(findLayer(withClass: "eyes-blink", in: rootLayer))
        XCTAssertNotNil(layer.animation(forKey: "eye-blink"))
    }

    @MainActor
    func testApplyStoresTransitionConfig() throws {
        let svg = try loadSVG("clawd-idle-follow")
        let document = SVGParser.parse(svg)
        let rootLayer = CALayerRenderer.build(document)

        CAAnimationBuilder.apply(document, to: rootLayer)

        let layer = try XCTUnwrap(findLayer(named: "eyes-js", in: rootLayer))
        XCTAssertNotNil(layer.value(forKey: "svgTransitions"))
    }

    @MainActor
    func testUnmatchedSelectorDoesNotCrash() {
        let document = SVGParser.parse(
            """
            <svg viewBox="0 0 15 16" xmlns="http://www.w3.org/2000/svg">
              <defs>
                <style>
                  .missing {
                    animation: ghost 1s infinite linear;
                  }

                  @keyframes ghost {
                    0% { opacity: 0; }
                    100% { opacity: 1; }
                  }
                </style>
              </defs>
              <rect id="torso" x="2" y="6" width="11" height="7" fill="#DE886D"/>
            </svg>
            """
        )
        let rootLayer = CALayerRenderer.build(document)

        CAAnimationBuilder.apply(document, to: rootLayer)

        XCTAssertNil(rootLayer.animationKeys())
    }

    @MainActor
    func testNestedAnimationsOnIdleLivingSVG() throws {
        let svg = try loadSVG("clawd-idle-living")
        let document = SVGParser.parse(svg)
        let rootLayer = CALayerRenderer.build(document)

        CAAnimationBuilder.apply(document, to: rootLayer)

        let actionBodyLayer = try XCTUnwrap(findLayer(withClass: "action-body", in: rootLayer))
        let breatheLayer = try XCTUnwrap(findLayer(withClass: "breathe-anim", in: rootLayer))

        XCTAssertNotNil(actionBodyLayer.animation(forKey: "action-body"))
        XCTAssertNotNil(breatheLayer.animation(forKey: "breathe"))

        var current = breatheLayer.superlayer
        var isDescendant = false
        while let layer = current {
            if layer === actionBodyLayer {
                isDescendant = true
                break
            }
            current = layer.superlayer
        }

        XCTAssertTrue(isDescendant)
    }

    @MainActor
    func testForwardsFillModeAnimation() throws {
        let animation = SVGAnimation(
            name: "settle",
            keyframes: [
                SVGKeyframe(offsets: [0], properties: ["transform": "scale(1)"]),
                SVGKeyframe(offsets: [1], properties: ["transform": "scale(0.95)"]),
            ]
        )
        let binding = TestBinding(animationName: "settle", duration: 3.6, fillMode: .forwards)

        let builtAnimation = try XCTUnwrap(
            CAAnimationBuilder.buildAnimation(from: animation, binding: binding)
        )

        XCTAssertEqual(builtAnimation.fillMode, .forwards)
        XCTAssertFalse(builtAnimation.isRemovedOnCompletion)
    }

    @MainActor
    func testDelayedAnimationHasBeginTime() throws {
        let animation = SVGAnimation(
            name: "delayed",
            keyframes: [
                SVGKeyframe(offsets: [0], properties: ["transform": "scale(1)"]),
                SVGKeyframe(offsets: [1], properties: ["transform": "scale(0.95)"]),
            ]
        )
        let binding = TestBinding(animationName: "delayed", duration: 1, delay: 3.6)
        let startTime = CACurrentMediaTime()

        let builtAnimation = try XCTUnwrap(
            CAAnimationBuilder.buildAnimation(from: animation, binding: binding)
        )

        XCTAssertGreaterThan(builtAnimation.beginTime, startTime + 3.0)
    }

    @MainActor
    func testCollapseSleepForwardsAnimations() throws {
        let svg = try loadSVG("clawd-collapse-sleep")
        let document = SVGParser.parse(svg)
        let rootLayer = CALayerRenderer.build(document)

        CAAnimationBuilder.apply(document, to: rootLayer)

        let layer = try XCTUnwrap(findLayer(withClass: "rest-body-frame", in: rootLayer))
        let animation = try XCTUnwrap(layer.animation(forKey: "body-frame"))

        XCTAssertEqual(animation.fillMode, .forwards)
        XCTAssertFalse(animation.isRemovedOnCompletion)
    }

    @MainActor
    func testCollapseSleepDelayedBreathAnimation() throws {
        let svg = try loadSVG("clawd-collapse-sleep")
        let document = SVGParser.parse(svg)
        let rootLayer = CALayerRenderer.build(document)

        CAAnimationBuilder.apply(document, to: rootLayer)

        let layer = try XCTUnwrap(findLayer(withClass: "rest-breathe", in: rootLayer))
        let animation = try XCTUnwrap(layer.animation(forKey: "sleep-breathe"))

        XCTAssertGreaterThan(animation.beginTime, 0)
    }

    @MainActor
    func testReverseDirectionReversesKeyTimes() throws {
        let animation = SVGAnimation(
            name: "reverse",
            keyframes: [
                SVGKeyframe(offsets: [0], properties: ["opacity": "0"]),
                SVGKeyframe(offsets: [0.25], properties: ["opacity": "0.5"]),
                SVGKeyframe(offsets: [1], properties: ["opacity": "1"]),
            ]
        )
        let binding = TestBinding(animationName: "reverse", duration: 1, direction: .reverse)

        let keyframeAnimation = try XCTUnwrap(
            CAAnimationBuilder.buildKeyframeAnimation(
                for: "opacity",
                keyframes: animation.keyframes,
                binding: binding
            )
        )
        let keyTimes = try XCTUnwrap(keyframeAnimation.keyTimes)

        XCTAssertEqual(keyTimes.count, 3)
        XCTAssertEqual(keyTimes[0].doubleValue, 0, accuracy: 0.0001)
        XCTAssertEqual(keyTimes[1].doubleValue, 0.75, accuracy: 0.0001)
        XCTAssertEqual(keyTimes[2].doubleValue, 1, accuracy: 0.0001)
    }

    @MainActor
    func testAlternateDirectionSetsAutoreverses() throws {
        let animation = SVGAnimation(
            name: "alternate",
            keyframes: [
                SVGKeyframe(offsets: [0], properties: ["opacity": "0"]),
                SVGKeyframe(offsets: [1], properties: ["opacity": "1"]),
            ]
        )
        let binding = TestBinding(animationName: "alternate", duration: 1, direction: .alternate)

        let builtAnimation = try XCTUnwrap(
            CAAnimationBuilder.buildAnimation(from: animation, binding: binding)
        )

        XCTAssertTrue(builtAnimation.autoreverses)
    }

    @MainActor
    func testStepEndSetsDiscreteCalculationMode() throws {
        let animation = SVGAnimation(
            name: "blink",
            keyframes: [
                SVGKeyframe(offsets: [0], properties: ["opacity": "1"]),
                SVGKeyframe(offsets: [1], properties: ["opacity": "0"]),
            ]
        )
        let binding = TestBinding(animationName: "blink", duration: 1, timingFunction: .stepEnd)

        let keyframeAnimation = try XCTUnwrap(
            CAAnimationBuilder.buildKeyframeAnimation(
                for: "opacity",
                keyframes: animation.keyframes,
                binding: binding
            )
        )

        XCTAssertEqual(keyframeAnimation.calculationMode, .discrete)
    }

    private func findLayer(named name: String, in layer: CALayer) -> CALayer? {
        if layer.name == name {
            return layer
        }

        for sublayer in layer.sublayers ?? [] {
            if let match = findLayer(named: name, in: sublayer) {
                return match
            }
        }

        return nil
    }

    private func findLayer(withClass className: String, in layer: CALayer) -> CALayer? {
        if let classes = layer.value(forKey: "svgClasses") as? [String],
           classes.contains(className) {
            return layer
        }

        for sublayer in layer.sublayers ?? [] {
            if let match = findLayer(withClass: className, in: sublayer) {
                return match
            }
        }

        return nil
    }

    private func applyTransform(_ transform: CATransform3D, to point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x * transform.m11) + (point.y * transform.m21) + transform.m41,
            y: (point.x * transform.m12) + (point.y * transform.m22) + transform.m42
        )
    }
}
