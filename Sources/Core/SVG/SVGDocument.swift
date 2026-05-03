import Foundation
import CoreGraphics

/// 解析后的 SVG 文档树。SVGParser 把原始 XML 转成这棵不可变结构供 CALayerRenderer 渲染。
///
/// 设计要点：
/// - 所有几何字段都是可选 `CGFloat?`，未声明时由渲染器按 SVG 默认值（多数为 0）兜底；
/// - `defs` 与 `defsChildren` 各存一份：前者按 id 索引便于 `<use>` 解引用，
///   后者保留顺序便于"渲染所有 def 内容"的全量遍历；
/// - 动画/过渡绑定分四类：CSS-by-class、CSS-by-id、节点 inline 绑定、CSS transition；
///   CALayerRenderer 把这些绑定按 selector 匹配回真正的 SVGNode 后再生成 CAAnimation。
struct SVGDocument: Sendable {
    var viewBox: SVGViewBox?
    var width: CGFloat?
    var height: CGFloat?
    /// SVG `shape-rendering` 属性，主要用于开启像素边界对齐（`crispEdges`）。
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

    /// 根据 `<use href="...">` 解引用 def 节点；找不到时返回 nil 让渲染器跳过这个 use。
    func referencedNode(for href: String) -> SVGNode? {
        guard let targetID = referencedDefID(from: href) else {
            return nil
        }
        return defs[targetID]
    }

    /// 容忍 `#foo` 与裸 `foo` 两种写法；空字符串视为无效。
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

/// SVG `viewBox` 的 4 元组。CALayerRenderer 据此把 SVG 坐标线性映射到 layer 坐标。
struct SVGViewBox: Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
}

/// 渲染节点的 sum type；`indirect` 是因为 group / clipPath 会嵌套自身。
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

/// `<g>` 节点。`inlineStyles` 保存原始 `style="..."` 拆分后的键值对；
/// 渲染时 inline 优先级高于 class 绑定，与 CSS 规范一致。
struct SVGGroup: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var fill: String?
    var stroke: String?
    var strokeWidth: CGFloat?
    var strokeLinecap: String?
    var strokeLinejoin: String?
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

/// `<use>` 是 SVG 的"引用复制"：渲染时把 href 指向的 def 节点克隆一份，
/// 自身字段（fill/transform 等）会覆盖被引用节点的同名属性。
struct SVGUse: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var href: String
    var transform: String?
    var fill: String?
    var stroke: String?
    var strokeWidth: CGFloat?
    var strokeLinecap: String?
    var strokeLinejoin: String?
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
    var strokeLinecap: String?
    var strokeLinejoin: String?
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
    var stroke: String?
    var strokeWidth: CGFloat?
    var strokeLinecap: String?
    var strokeLinejoin: String?
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

/// `<path>`：`d` 属性保留原始字符串，由 `PathParser` 在渲染时拆成 CGPath 命令。
struct SVGPath: Sendable {
    var id: String?
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var d: String
    var fill: String?
    var stroke: String?
    var strokeWidth: CGFloat?
    var strokeLinecap: String?
    var strokeLinejoin: String?
}

struct SVGPolygon: Sendable {
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

/// `<clipPath>` 在 defs 中定义，被其他节点通过 `clipPathRef` 引用。
struct SVGClipPathDef: Sendable {
    var id: String
    var classes: [String]
    var inlineStyles: [String: String]
    var clipPathRef: String?
    var children: [SVGNode]
}

/// CSS `@keyframes` 定义。`offsets` 把多关键帧合并写法（`0%, 50% { ... }`）展平成多个 offset。
struct SVGAnimation: Sendable {
    var name: String
    var keyframes: [SVGKeyframe]
}

struct SVGKeyframe: Sendable {
    var offsets: [CGFloat]
    var properties: [String: String]
}

/// `class { color: red; }` 这类不带动画的样式绑定。CALayerRenderer 在生成 layer 时直接吃掉。
struct SVGStaticStyleBinding: Sendable {
    var selector: CSSSelector
    var properties: [String: String]
}

/// CSS 短手 `animation` 解析后的完整绑定（必须有 name + duration）。
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

/// 长手分写的 `animation-*` 绑定，所有字段可选；与短手在 CALayerRenderer 中合并应用。
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

/// 节点定位元组，用于把"内联绑定"准确匹配回 SVG 树中那个具体节点。
/// `nodePath` 是按层级编号的路径（例如 `0/2/1`）。
struct SVGNodeTarget: Sendable, Equatable {
    var nodePath: String
    var nodeID: String?
    var classes: [String]
}

/// 节点 `style="animation:..."` 的内联动画绑定。语义同 CSS 版本，但匹配更精确。
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

/// CSS `transition: <prop> <duration> ...` 绑定，CALayerRenderer 据此为单个属性建动画。
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

/// 仅支持 class / id 两种选择器：项目资产里没有更复杂的选择器需求。
enum CSSSelector: Sendable {
    case className(String)
    case id(String)
}

extension CSSSelector: Equatable {
    static func == (lhs: CSSSelector, rhs: CSSSelector) -> Bool {
        switch (lhs, rhs) {
        case let (.className(lhsName), .className(rhsName)):
            return lhsName == rhsName
        case let (.id(lhsName), .id(rhsName)):
            return lhsName == rhsName
        default:
            return false
        }
    }
}

/// CSS 时间函数；CAAnimationBuilder 会把它转成 `CAMediaTimingFunction`。
/// `stepEnd` 用 linear 近似——CAAnimation 没有原生 step-end，但项目动画里只用作占位。
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

/// `transform-origin` 表达式的解析结果：每个轴可能是绝对像素也可能是百分比。
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
