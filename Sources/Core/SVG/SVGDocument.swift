import Foundation
import CoreGraphics

struct SVGDocument: Sendable {
    var viewBox: SVGViewBox?
    var width: CGFloat?
    var height: CGFloat?
    var shapeRendering: String?
    var defsChildren: [SVGNode]
    var defs: [String: SVGNode]
    var rootChildren: [SVGNode]
    var animations: [String: SVGAnimation]
    var staticStyleBindings: [SVGStaticStyleBinding]
    var animationBindings: [SVGAnimationBinding]
    var animationStyleBindings: [SVGAnimationStyleBinding]
    var inlineAnimationBindings: [SVGInlineAnimationBinding]
    var transitions: [SVGTransitionBinding]
    var inlineTransitionBindings: [SVGInlineTransitionBinding]

    func referencedNode(for use: SVGUse) -> SVGNode? {
        referencedNode(for: use.href)
    }

    func referencedNode(for href: String) -> SVGNode? {
        guard let targetID = referencedDefID(from: href) else {
            return nil
        }
        return defs[targetID]
    }

    private func referencedDefID(from href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("#") {
            let targetID = String(trimmed.dropFirst())
            return targetID.isEmpty ? nil : targetID
        }
        return trimmed
    }
}

struct SVGViewBox: Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
}

indirect enum SVGNode: Sendable {
    case group(SVGGroup)
    case rect(SVGRect)
    case use(SVGUse)
    case circle(SVGCircle)
    case ellipse(SVGEllipse)
    case line(SVGLine)
    case path(SVGPath)
    case polygon(SVGPolygon)
    case polyline(SVGPolyline)
    case clipPath(SVGClipPathDef)
}

struct SVGGroup: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var fill: String?
    var opacity: CGFloat?
    var transform: String?
    var children: [SVGNode]
}

struct SVGRect: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var x: CGFloat?
    var y: CGFloat?
    var width: CGFloat?
    var height: CGFloat?
    var rx: CGFloat?
    var ry: CGFloat?
    var transform: String?
    var fill: String?
    var stroke: String?
    var strokeWidth: CGFloat?
    var opacity: CGFloat?
}

struct SVGUse: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var href: String
    var transform: String?
    var fill: String?
    var x: CGFloat?
    var y: CGFloat?
}

struct SVGCircle: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var cx: CGFloat?
    var cy: CGFloat?
    var r: CGFloat?
    var fill: String?
    var stroke: String?
    var strokeWidth: CGFloat?
    var opacity: CGFloat?
}

struct SVGEllipse: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var cx: CGFloat?
    var cy: CGFloat?
    var rx: CGFloat?
    var ry: CGFloat?
    var fill: String?
    var opacity: CGFloat?
}

struct SVGLine: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var x1: CGFloat?
    var y1: CGFloat?
    var x2: CGFloat?
    var y2: CGFloat?
    var stroke: String?
    var strokeWidth: CGFloat?
    var strokeLinecap: String?
}

struct SVGPath: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var d: String
    var fill: String?
    var stroke: String?
    var strokeWidth: CGFloat?
    var strokeLinejoin: String?
}

struct SVGPolygon: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var points: String
    var fill: String?
    var opacity: CGFloat?
}

struct SVGPolyline: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var points: String
    var fill: String?
    var stroke: String?
    var strokeWidth: CGFloat?
    var strokeLinecap: String?
    var strokeLinejoin: String?
}

struct SVGClipPathDef: Sendable {
    var id: String
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var children: [SVGNode]
}

struct SVGAnimation: Sendable {
    var name: String
    var keyframes: [SVGKeyframe]
}

struct SVGKeyframe: Sendable {
    var offsets: [CGFloat]
    var properties: [String: String]
}

struct SVGStaticStyleBinding: Sendable {
    var selector: CSSSelector
    var properties: [String: String]
}

struct SVGAnimationBinding: Sendable {
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

struct SVGAnimationStyleBinding: Sendable {
    var selector: CSSSelector
    var animationName: String?
    var duration: TimeInterval?
    var timingFunction: TimingFunction?
    var iterationCount: AnimationIterationCount?
    var direction: AnimationDirection?
    var delay: TimeInterval?
    var fillMode: AnimationFillMode?
    var transformOrigin: SVGTransformOrigin?
    var transformBox: String?
}

struct SVGNodeTarget: Sendable, Equatable {
    var nodePath: String
    var nodeID: String?
    var classes: [String]
}

struct SVGInlineAnimationBinding: Sendable {
    var target: SVGNodeTarget
    var animationName: String
    var duration: TimeInterval
    var timingFunction: TimingFunction
    var iterationCount: AnimationIterationCount
    var direction: AnimationDirection
    var delay: TimeInterval
    var fillMode: AnimationFillMode
    var transformOrigin: SVGTransformOrigin?
    var transformBox: String?

    var nodePath: String { target.nodePath }
    var nodeID: String? { target.nodeID }
    var classes: [String] { target.classes }
}

struct SVGTransitionBinding: Sendable {
    var selector: CSSSelector
    var property: String
    var duration: TimeInterval
    var timingFunction: TimingFunction
    var delay: TimeInterval
}

struct SVGInlineTransitionBinding: Sendable {
    var target: SVGNodeTarget
    var property: String
    var duration: TimeInterval
    var timingFunction: TimingFunction
    var delay: TimeInterval

    var nodePath: String { target.nodePath }
    var nodeID: String? { target.nodeID }
    var classes: [String] { target.classes }
}

enum CSSSelector: Sendable {
    case className(String)
    case id(String)
}

enum TimingFunction: Sendable {
    case easeInOut
    case linear
    case easeOut
    case easeIn
    case stepEnd
    case cubicBezier(CGFloat, CGFloat, CGFloat, CGFloat)
}

enum AnimationIterationCount: Sendable {
    case infinite
    case count(Double)
}

enum AnimationDirection: Sendable {
    case normal
    case reverse
    case alternate
    case alternateReverse
}

enum AnimationFillMode: Sendable {
    case none
    case forwards
    case backwards
    case both
}

struct SVGTransformOrigin: Sendable, Equatable {
    var x: SVGTransformOriginComponent
    var y: SVGTransformOriginComponent
}

enum SVGTransformOriginComponent: Sendable, Equatable {
    case px(CGFloat)
    case percent(CGFloat)
}

extension SVGAnimationBinding: AnimationBinding {}
extension SVGInlineAnimationBinding: AnimationBinding {}
