import AppKit
import QuartzCore

/// 把 `SVGDocument` 转成可直接挂载的 CALayer 树。
///
/// 与浏览器 SVG 渲染的对应关系：
/// - rootLayer 配置 viewBox 平移 + isGeometryFlipped 翻转 Y 轴；
/// - 每个 SVG 节点对应一个 CALayer / CAShapeLayer，按层级嵌套；
/// - `<use>` 通过 `visitedDefs` 防止循环引用；
/// - `shape-rendering=crispEdges` 时关闭抗锯齿并向下传播。
///
/// 静态样式 / class / id 绑定的应用顺序：节点本身属性 → CSS class → CSS id → 内联 style。
@MainActor
enum CALayerRenderer {
    /// 渲染入口。返回的 CALayer 自身就是可作为 sublayer 添加到任意 host 的根。
    static func build(_ document: SVGDocument) -> CALayer {
        let rootLayer = makeLayer()
        rootLayer.bounds = rootBounds(for: document)
        rootLayer.masksToBounds = true
        rootLayer.isGeometryFlipped = true

        if let viewBox = document.viewBox,
           viewBox.x != 0 || viewBox.y != 0 {
            rootLayer.sublayerTransform = CATransform3DMakeTranslation(-viewBox.x, -viewBox.y, 0)
        }

        let crispEdges = document.shapeRendering == "crispEdges"
        if crispEdges {
            rootLayer.edgeAntialiasingMask = []
        }

        for (index, node) in document.rootChildren.enumerated() {
            let nodePath = "root/\(index)"
            guard let layer = buildLayer(
                for: node,
                inheritedFill: nil,
                inheritedStroke: nil,
                inheritedStrokeWidth: nil,
                inheritedStrokeLinecap: nil,
                inheritedStrokeLinejoin: nil,
                document: document,
                nodePath: nodePath,
                visitedDefs: []
            ) else {
                continue
            }

            rootLayer.addSublayer(layer)
        }

        if crispEdges {
            propagateCrispEdges(rootLayer)
        }

        return rootLayer
    }

    /// 像素级命中检测：透明像素（fill = 透明 / opacity = 0）一律不算命中。
    /// PetView 用它判定鼠标是否真落在桌宠身上以决定是否要 ignoresMouseEvents。
    static func hitTest(point: CGPoint, in rootLayer: CALayer) -> Bool {
        hitTest(point: point, in: rootLayer, from: rootLayer)
    }

    private static func buildLayer(
        for node: SVGNode,
        inheritedFill: String?,
        inheritedStroke: String?,
        inheritedStrokeWidth: CGFloat?,
        inheritedStrokeLinecap: String?,
        inheritedStrokeLinejoin: String?,
        document: SVGDocument,
        nodePath: String,
        visitedDefs: Set<String> = []
    ) -> CALayer? {
        switch node {
        case .group(let group):
            let layer = makeLayer()
            layer.name = group.id
            storeMetadata(on: layer, nodePath: nodePath, classes: group.classes)

            if let opacity = group.opacity {
                layer.opacity = Float(opacity)
            }

            if let transform = group.transform {
                layer.transform = TransformParser.parse(transform)
            }

            let cssFill = resolvedCSSProperty("fill", id: group.id, classes: group.classes, document: document)
            let cssStroke = resolvedCSSProperty("stroke", id: group.id, classes: group.classes, document: document)
            let childFill = cssFill ?? group.fill ?? inheritedFill
            let childStroke = cssStroke ?? group.stroke ?? inheritedStroke
            let childStrokeWidth = group.strokeWidth ?? inheritedStrokeWidth
            let childStrokeLinecap = group.strokeLinecap ?? inheritedStrokeLinecap
            let childStrokeLinejoin = group.strokeLinejoin ?? inheritedStrokeLinejoin
            for (index, childNode) in group.children.enumerated() {
                let childPath = "\(nodePath)/\(index)"
                guard let childLayer = buildLayer(
                    for: childNode,
                    inheritedFill: childFill,
                    inheritedStroke: childStroke,
                    inheritedStrokeWidth: childStrokeWidth,
                    inheritedStrokeLinecap: childStrokeLinecap,
                    inheritedStrokeLinejoin: childStrokeLinejoin,
                    document: document,
                    nodePath: childPath,
                    visitedDefs: visitedDefs
                ) else {
                    continue
                }

                layer.addSublayer(childLayer)
            }

            applyStaticStyleMetadata(to: layer, id: group.id, classes: group.classes, document: document)
            applyInlineStyles(group.inlineStyles, to: layer, hasExplicitOpacity: group.opacity != nil)
            applyClipPath(group.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .rect(let rect):
            let layer = makeLayer()
            let x = rect.x ?? 0
            let y = rect.y ?? 0
            let width = rect.width ?? 0
            let height = rect.height ?? 0

            layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            layer.position = CGPoint(x: x + (width / 2), y: y + (height / 2))
            layer.backgroundColor = ColorParser.parse(rect.fill ?? inheritedFill)

            let strokeColor = ColorParser.parse(rect.stroke ?? inheritedStroke)
            layer.borderColor = strokeColor
            layer.borderWidth = resolvedLineWidth(
                strokeColor: strokeColor,
                strokeWidth: rect.strokeWidth ?? inheritedStrokeWidth
            )
            layer.cornerRadius = resolvedCornerRadius(rx: rect.rx, ry: rect.ry)
            layer.opacity = rect.opacity.map(Float.init) ?? layer.opacity
            layer.name = rect.id

            if let transform = rect.transform {
                layer.transform = svgAttributeTransform(transform, position: layer.position)
            }

            storeMetadata(on: layer, nodePath: nodePath, classes: rect.classes)
            applyStaticStyleMetadata(to: layer, id: rect.id, classes: rect.classes, document: document)
            applyInlineStyles(rect.inlineStyles, to: layer, hasExplicitOpacity: rect.opacity != nil)
            applyClipPath(rect.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .circle(let circle):
            let layer = makeShapeLayer()
            let cx = circle.cx ?? 0
            let cy = circle.cy ?? 0
            let radius = max(circle.r ?? 0, 0)

            layer.path = CGPath(
                ellipseIn: CGRect(
                    x: cx - radius,
                    y: cy - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            )
            layer.fillColor = ColorParser.parse(circle.fill ?? inheritedFill)
            let strokeColor = ColorParser.parse(circle.stroke ?? inheritedStroke)
            layer.strokeColor = strokeColor
            layer.lineWidth = resolvedLineWidth(
                strokeColor: strokeColor,
                strokeWidth: circle.strokeWidth ?? inheritedStrokeWidth
            )
            layer.lineCap = lineCap(for: circle.strokeLinecap ?? inheritedStrokeLinecap)
            layer.lineJoin = lineJoin(for: circle.strokeLinejoin ?? inheritedStrokeLinejoin)
            layer.opacity = circle.opacity.map(Float.init) ?? layer.opacity
            layer.name = circle.id

            storeMetadata(on: layer, nodePath: nodePath, classes: circle.classes)
            applyStaticStyleMetadata(to: layer, id: circle.id, classes: circle.classes, document: document)
            applyInlineStyles(circle.inlineStyles, to: layer, hasExplicitOpacity: circle.opacity != nil)
            applyClipPath(circle.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .ellipse(let ellipse):
            let layer = makeShapeLayer()
            let cx = ellipse.cx ?? 0
            let cy = ellipse.cy ?? 0
            let rx = max(ellipse.rx ?? 0, 0)
            let ry = max(ellipse.ry ?? 0, 0)

            layer.path = CGPath(
                ellipseIn: CGRect(
                    x: cx - rx,
                    y: cy - ry,
                    width: rx * 2,
                    height: ry * 2
                ),
                transform: nil
            )
            layer.fillColor = ColorParser.parse(ellipse.fill ?? inheritedFill)
            let strokeColor = ColorParser.parse(ellipse.stroke ?? inheritedStroke)
            layer.strokeColor = strokeColor
            layer.lineWidth = resolvedLineWidth(
                strokeColor: strokeColor,
                strokeWidth: ellipse.strokeWidth ?? inheritedStrokeWidth
            )
            layer.lineCap = lineCap(for: ellipse.strokeLinecap ?? inheritedStrokeLinecap)
            layer.lineJoin = lineJoin(for: ellipse.strokeLinejoin ?? inheritedStrokeLinejoin)
            layer.opacity = ellipse.opacity.map(Float.init) ?? layer.opacity
            layer.name = ellipse.id

            storeMetadata(on: layer, nodePath: nodePath, classes: ellipse.classes)
            applyStaticStyleMetadata(to: layer, id: ellipse.id, classes: ellipse.classes, document: document)
            applyInlineStyles(ellipse.inlineStyles, to: layer, hasExplicitOpacity: ellipse.opacity != nil)
            applyClipPath(ellipse.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .line(let line):
            let layer = makeShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: line.x1 ?? 0, y: line.y1 ?? 0))
            path.addLine(to: CGPoint(x: line.x2 ?? 0, y: line.y2 ?? 0))

            let strokeColor = ColorParser.parse(line.stroke ?? inheritedStroke)
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = strokeColor
            layer.lineWidth = resolvedLineWidth(
                strokeColor: strokeColor,
                strokeWidth: line.strokeWidth ?? inheritedStrokeWidth
            )
            layer.lineCap = lineCap(for: line.strokeLinecap ?? inheritedStrokeLinecap)
            layer.name = line.id

            storeMetadata(on: layer, nodePath: nodePath, classes: line.classes)
            applyStaticStyleMetadata(to: layer, id: line.id, classes: line.classes, document: document)
            applyInlineStyles(line.inlineStyles, to: layer, hasExplicitOpacity: false)
            applyClipPath(line.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .path(let path):
            guard let cgPath = PathParser.parsePath(path.d) else {
                return nil
            }

            let layer = makeShapeLayer()
            let strokeColor = ColorParser.parse(path.stroke ?? inheritedStroke)

            layer.path = cgPath
            layer.fillColor = ColorParser.parse(path.fill ?? inheritedFill)
            layer.strokeColor = strokeColor
            layer.lineWidth = resolvedLineWidth(
                strokeColor: strokeColor,
                strokeWidth: path.strokeWidth ?? inheritedStrokeWidth
            )
            layer.lineCap = lineCap(for: path.strokeLinecap ?? inheritedStrokeLinecap)
            layer.lineJoin = lineJoin(for: path.strokeLinejoin ?? inheritedStrokeLinejoin)
            layer.name = path.id

            storeMetadata(on: layer, nodePath: nodePath, classes: path.classes)
            applyStaticStyleMetadata(to: layer, id: path.id, classes: path.classes, document: document)
            applyInlineStyles(path.inlineStyles, to: layer, hasExplicitOpacity: false)
            applyClipPath(path.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .polygon(let polygon):
            guard let cgPath = PathParser.parsePolygonPoints(polygon.points) else {
                return nil
            }

            let layer = makeShapeLayer()
            layer.path = cgPath
            layer.fillColor = ColorParser.parse(polygon.fill ?? inheritedFill)
            let strokeColor = ColorParser.parse(polygon.stroke ?? inheritedStroke)
            layer.strokeColor = strokeColor
            layer.lineWidth = resolvedLineWidth(
                strokeColor: strokeColor,
                strokeWidth: polygon.strokeWidth ?? inheritedStrokeWidth
            )
            layer.lineCap = lineCap(for: polygon.strokeLinecap ?? inheritedStrokeLinecap)
            layer.lineJoin = lineJoin(for: polygon.strokeLinejoin ?? inheritedStrokeLinejoin)
            layer.opacity = polygon.opacity.map(Float.init) ?? layer.opacity
            layer.name = polygon.id

            storeMetadata(on: layer, nodePath: nodePath, classes: polygon.classes)
            applyStaticStyleMetadata(to: layer, id: polygon.id, classes: polygon.classes, document: document)
            applyInlineStyles(polygon.inlineStyles, to: layer, hasExplicitOpacity: polygon.opacity != nil)
            applyClipPath(polygon.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .polyline(let polyline):
            guard let cgPath = PathParser.parsePolylinePoints(polyline.points) else {
                return nil
            }

            let layer = makeShapeLayer()
            let strokeColor = ColorParser.parse(polyline.stroke ?? inheritedStroke)

            layer.path = cgPath
            layer.fillColor = ColorParser.parse(polyline.fill ?? inheritedFill)
            layer.strokeColor = strokeColor
            layer.lineWidth = resolvedLineWidth(
                strokeColor: strokeColor,
                strokeWidth: polyline.strokeWidth ?? inheritedStrokeWidth
            )
            layer.lineCap = lineCap(for: polyline.strokeLinecap ?? inheritedStrokeLinecap)
            layer.lineJoin = lineJoin(for: polyline.strokeLinejoin ?? inheritedStrokeLinejoin)
            layer.name = polyline.id

            storeMetadata(on: layer, nodePath: nodePath, classes: polyline.classes)
            applyStaticStyleMetadata(to: layer, id: polyline.id, classes: polyline.classes, document: document)
            applyInlineStyles(polyline.inlineStyles, to: layer, hasExplicitOpacity: false)
            applyClipPath(polyline.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .use(let use):
            guard let defID = referencedDefID(from: use.href),
                  !visitedDefs.contains(defID),
                  let referencedNode = document.referencedNode(for: use) else {
                return nil
            }

            let layer = buildLayer(
                for: referencedNode,
                inheritedFill: use.fill ?? inheritedFill,
                inheritedStroke: use.stroke ?? inheritedStroke,
                inheritedStrokeWidth: use.strokeWidth ?? inheritedStrokeWidth,
                inheritedStrokeLinecap: use.strokeLinecap ?? inheritedStrokeLinecap,
                inheritedStrokeLinejoin: use.strokeLinejoin ?? inheritedStrokeLinejoin,
                document: document,
                nodePath: nodePath,
                visitedDefs: visitedDefs.union([defID])
            ) ?? makeLayer()

            var useTransform = use.transform.map(TransformParser.parse) ?? CATransform3DIdentity
            if let x = use.x, x != 0 {
                useTransform = CATransform3DTranslate(useTransform, x, 0, 0)
            }

            if let y = use.y, y != 0 {
                useTransform = CATransform3DTranslate(useTransform, 0, y, 0)
            }

            if !CATransform3DIsIdentity(useTransform) {
                layer.transform = useTransform
            }

            layer.name = use.id
            storeMetadata(on: layer, nodePath: nodePath, classes: use.classes)
            applyStaticStyleMetadata(to: layer, id: use.id, classes: use.classes, document: document)
            applyInlineStyles(use.inlineStyles, to: layer, hasExplicitOpacity: false)
            applyClipPath(use.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .clipPath(let clipPath):
            let layer = makeLayer()
            layer.name = clipPath.id
            storeMetadata(on: layer, nodePath: nodePath, classes: clipPath.classes)

            for (index, childNode) in clipPath.children.enumerated() {
                let childPath = "\(nodePath)/\(index)"
                guard let childLayer = buildLayer(
                    for: childNode,
                    inheritedFill: "black",
                    inheritedStroke: nil,
                    inheritedStrokeWidth: nil,
                    inheritedStrokeLinecap: nil,
                    inheritedStrokeLinejoin: nil,
                    document: document,
                    nodePath: childPath,
                    visitedDefs: visitedDefs
                ) else {
                    continue
                }

                layer.addSublayer(childLayer)
            }

            applyInlineStyles(clipPath.inlineStyles, to: layer, hasExplicitOpacity: false)
            return layer
        }
    }
}

private extension CALayerRenderer {
    static var defaultContentScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2.0
    }

    static func makeLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsScale = defaultContentScale
        return layer
    }

    static func makeShapeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.contentsScale = defaultContentScale
        return layer
    }

    static func hitTest(point: CGPoint, in layer: CALayer, from sourceLayer: CALayer) -> Bool {
        guard !layer.isHidden, layer.opacity > 0 else {
            return false
        }

        let localPoint = layer.convert(point, from: sourceLayer)

        if let mask = layer.mask,
           !hitTest(point: localPoint, in: mask, from: layer) {
            return false
        }

        let sublayers = layer.sublayers ?? []
        for sublayer in sublayers.reversed() {
            if hitTest(point: point, in: sublayer, from: sourceLayer) {
                return true
            }
        }

        guard sublayers.isEmpty else {
            return false
        }

        if let shapeLayer = layer as? CAShapeLayer {
            return hitTestShapeLayer(shapeLayer, point: localPoint)
        }

        guard let backgroundColor = layer.backgroundColor,
              backgroundColor.alpha > 0 else {
            return false
        }

        return layer.bounds.contains(localPoint)
    }

    static func hitTestShapeLayer(_ layer: CAShapeLayer, point: CGPoint) -> Bool {
        guard let path = layer.path else {
            return false
        }

        if let fillColor = layer.fillColor,
           fillColor.alpha > 0,
           path.contains(point, using: .winding, transform: .identity) {
            return true
        }

        guard let strokeColor = layer.strokeColor,
              strokeColor.alpha > 0,
              layer.lineWidth > 0 else {
            return false
        }

        let strokedPath = path.copy(
            strokingWithWidth: layer.lineWidth,
            lineCap: cgLineCap(for: layer.lineCap),
            lineJoin: cgLineJoin(for: layer.lineJoin),
            miterLimit: layer.miterLimit
        )

        return strokedPath.contains(point, using: .winding, transform: .identity)
    }

    static func cgLineCap(for value: CAShapeLayerLineCap) -> CGLineCap {
        switch value {
        case .round:
            return .round
        case .square:
            return .square
        default:
            return .butt
        }
    }

    static func cgLineJoin(for value: CAShapeLayerLineJoin) -> CGLineJoin {
        switch value {
        case .round:
            return .round
        case .bevel:
            return .bevel
        default:
            return .miter
        }
    }

    static func rootBounds(for document: SVGDocument) -> CGRect {
        if let viewBox = document.viewBox {
            return CGRect(x: 0, y: 0, width: viewBox.width, height: viewBox.height)
        }

        return CGRect(
            x: 0,
            y: 0,
            width: document.width ?? 15,
            height: document.height ?? 16
        )
    }

    static func storeMetadata(on layer: CALayer, nodePath: String, classes: [String]) {
        layer.setValue(nodePath, forKey: "svgNodePath")
        layer.setValue(classes, forKey: "svgClasses")
    }

    static func applyStaticStyleMetadata(
        to layer: CALayer,
        id: String?,
        classes: [String],
        document: SVGDocument
    ) {
        let matchedBindings = document.staticStyleBindings
            .enumerated()
            .filter { matches($0.element.selector, id: id, classes: classes) }
            .sorted { lhs, rhs in
                let lhsSpecificity = selectorSpecificity(lhs.element.selector)
                let rhsSpecificity = selectorSpecificity(rhs.element.selector)
                if lhsSpecificity == rhsSpecificity {
                    return lhs.offset < rhs.offset
                }
                return lhsSpecificity < rhsSpecificity
            }
            .map(\.element)

        // Resolve transform-box before applying transform-origin.
        var effectiveTransformBox: String?
        var effectiveTransformOrigin: String?
        for binding in matchedBindings {
            if let tb = binding.properties["transform-box"] { effectiveTransformBox = tb }
            if let to = binding.properties["transform-origin"] { effectiveTransformOrigin = to }
        }
        if let transformOrigin = effectiveTransformOrigin {
            layer.setValue(transformOrigin, forKey: "svgTransformOrigin")
            let resolvedBox = effectiveTransformBox ?? "view-box"
            applyTransformOrigin(transformOrigin, to: layer, transformBox: resolvedBox, viewBox: document.viewBox)
        }
        if let transformBox = effectiveTransformBox {
            layer.setValue(transformBox, forKey: "svgTransformBox")
        }

        for binding in matchedBindings {

            if let opacityStr = binding.properties["opacity"],
               let opacity = Double(opacityStr) {
                layer.opacity = Float(opacity)
            }

            if let visibility = binding.properties["visibility"] {
                if visibility.lowercased() == "hidden" {
                    layer.isHidden = true
                }
            }

            if let fill = binding.properties["fill"] {
                if let shapeLayer = layer as? CAShapeLayer {
                    shapeLayer.fillColor = ColorParser.parse(fill)
                } else if (layer.sublayers ?? []).isEmpty {
                    layer.backgroundColor = ColorParser.parse(fill)
                }
            }

            if let stroke = binding.properties["stroke"], let shapeLayer = layer as? CAShapeLayer {
                shapeLayer.strokeColor = ColorParser.parse(stroke)
            }

            if let strokeWidth = binding.properties["stroke-width"], let shapeLayer = layer as? CAShapeLayer {
                if let width = parseCSSLength(strokeWidth) {
                    shapeLayer.lineWidth = CGFloat(width)
                }
            }
        }
    }

    static func applyTransformOrigin(_ rawValue: String, to layer: CALayer) {
        guard let origin = CSSParser.resolvedTransformOrigin(from: rawValue) else {
            return
        }
        setAnchorPoint(origin, on: layer)
    }

    static func applyTransformOrigin(
        _ rawValue: String,
        to layer: CALayer,
        transformBox: String,
        viewBox: SVGViewBox?
    ) {
        guard let origin = CSSParser.resolvedTransformOrigin(from: rawValue) else {
            return
        }
        if transformBox == "fill-box" || viewBox == nil {
            setAnchorPoint(origin, on: layer)
            return
        }
        // view-box: resolve percentage/keyword origins against viewBox, then convert to px.
        let vb = viewBox!
        let resolved = SVGTransformOrigin(
            x: resolveViewBoxComponent(origin.x, offset: vb.x, size: vb.width),
            y: resolveViewBoxComponent(origin.y, offset: vb.y, size: vb.height)
        )
        setAnchorPoint(resolved, on: layer)
    }

    static func resolveViewBoxComponent(
        _ component: SVGTransformOriginComponent,
        offset: CGFloat,
        size: CGFloat
    ) -> SVGTransformOriginComponent {
        switch component {
        case .percent(let pct):
            return .px(offset + size * pct / 100)
        case .px:
            return component
        }
    }

    static func matches(_ selector: CSSSelector, id: String?, classes: [String]) -> Bool {
        switch selector {
        case .className(let className):
            return classes.contains(className)
        case .id(let targetID):
            return id == targetID
        }
    }

    static func selectorSpecificity(_ selector: CSSSelector) -> Int {
        switch selector {
        case .className:
            return 10
        case .id:
            return 100
        }
    }

    static func applyInlineStyles(
        _ inlineStyles: [String: String],
        to layer: CALayer,
        hasExplicitOpacity: Bool
    ) {
        for (property, rawValue) in inlineStyles {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continue
            }

            switch property {
            case "opacity":
                guard !hasExplicitOpacity,
                      let opacity = Double(value) else {
                    continue
                }
                layer.opacity = Float(opacity)
            case "visibility":
                if value.lowercased() == "hidden" {
                    layer.isHidden = true
                }
            default:
                continue
            }
        }
    }

    static func applyClipPath(
        _ clipPathRef: String?,
        to layer: CALayer,
        document: SVGDocument,
        nodePath: String
    ) {
        guard let clipPathRef,
              let referencedNode = document.defs[clipPathRef],
              case .clipPath(let clipPath) = referencedNode,
              let maskLayer = buildLayer(
                for: .clipPath(clipPath),
                inheritedFill: "black",
                inheritedStroke: nil,
                inheritedStrokeWidth: nil,
                inheritedStrokeLinecap: nil,
                inheritedStrokeLinejoin: nil,
                document: document,
                nodePath: "\(nodePath)/clipPath",
                visitedDefs: []
              ) else {
            return
        }

        layer.mask = maskLayer
    }

    /// SVG attribute `transform` operates in parent coordinates around (0,0).
    /// CALayer applies `transform` around the layer's anchorPoint (= position).
    /// Compensate by moving the layer-space origin onto the parent-space position,
    /// applying the SVG matrix there, then moving back.
    /// T_ca = translate(pos) · T_svg · translate(-pos)
    static func svgAttributeTransform(_ svgTransform: String, position: CGPoint) -> CATransform3D {
        let parsed = TransformParser.parse(svgTransform)
        guard position.x != 0 || position.y != 0 else {
            return parsed
        }
        let toPosition = CATransform3DMakeTranslation(position.x, position.y, 0)
        let fromPosition = CATransform3DMakeTranslation(-position.x, -position.y, 0)
        return CATransform3DConcat(CATransform3DConcat(toPosition, parsed), fromPosition)
    }

    static func propagateCrispEdges(_ layer: CALayer) {
        for sublayer in layer.sublayers ?? [] {
            sublayer.edgeAntialiasingMask = []
            propagateCrispEdges(sublayer)
        }
    }

    static func parseCSSLength(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("px") {
            return Double(String(trimmed.dropLast(2)))
        }
        return Double(trimmed)
    }

    static func resolvedCSSProperty(
        _ property: String,
        id: String?,
        classes: [String],
        document: SVGDocument
    ) -> String? {
        var result: String?
        let bindings = document.staticStyleBindings
            .enumerated()
            .filter { matches($0.element.selector, id: id, classes: classes) }
            .sorted { lhs, rhs in
                let lhsSpec = selectorSpecificity(lhs.element.selector)
                let rhsSpec = selectorSpecificity(rhs.element.selector)
                return lhsSpec == rhsSpec ? lhs.offset < rhs.offset : lhsSpec < rhsSpec
            }
        for (_, binding) in bindings {
            if let value = binding.properties[property] {
                result = value
            }
        }
        return result
    }

    static func resolvedCornerRadius(rx: CGFloat?, ry: CGFloat?) -> CGFloat {
        switch (rx, ry) {
        case let (.some(rx), .some(ry)):
            return min(rx, ry)
        case let (.some(rx), .none):
            return rx
        case let (.none, .some(ry)):
            return ry
        case (.none, .none):
            return 0
        }
    }

    static func resolvedLineWidth(strokeColor: CGColor?, strokeWidth: CGFloat?) -> CGFloat {
        guard strokeColor != nil else {
            return 0
        }

        return strokeWidth ?? 1
    }

    static func lineCap(for value: String?) -> CAShapeLayerLineCap {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "round":
            return .round
        case "square":
            return .square
        default:
            return .butt
        }
    }

    static func lineJoin(for value: String?) -> CAShapeLayerLineJoin {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "round":
            return .round
        case "bevel":
            return .bevel
        default:
            return .miter
        }
    }

    static func referencedDefID(from href: String) -> String? {
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

extension CALayerRenderer {
    static func setAnchorPoint(_ origin: SVGTransformOrigin, on layer: CALayer) {
        let oldAnchorPoint = layer.anchorPoint

        if needsBoundingBox(for: origin, on: layer) {
            let bbox = contentBoundingBox(of: layer)

            if !bbox.isNull, !bbox.isEmpty {
                layer.bounds = bbox
                layer.position = CGPoint(
                    x: bbox.minX + (oldAnchorPoint.x * bbox.width),
                    y: bbox.minY + (oldAnchorPoint.y * bbox.height)
                )
            }
        }

        let bounds = layer.bounds
        let svgOriginX = layer.position.x - oldAnchorPoint.x * bounds.width
        let svgOriginY = layer.position.y - oldAnchorPoint.y * bounds.height
        var newAnchorPoint = oldAnchorPoint

        if bounds.width != 0 {
            switch origin.x {
            case .px(let value):
                newAnchorPoint.x = (value - svgOriginX) / bounds.width
            case .percent(let value):
                newAnchorPoint.x = value / 100
            }
        }

        if bounds.height != 0 {
            switch origin.y {
            case .px(let value):
                newAnchorPoint.y = (value - svgOriginY) / bounds.height
            case .percent(let value):
                newAnchorPoint.y = value / 100
            }
        }

        let dx = (newAnchorPoint.x - oldAnchorPoint.x) * bounds.width
        let dy = (newAnchorPoint.y - oldAnchorPoint.y) * bounds.height

        layer.anchorPoint = newAnchorPoint
        layer.position = CGPoint(x: layer.position.x + dx, y: layer.position.y + dy)
    }

    static func needsBoundingBox(for _: SVGTransformOrigin, on layer: CALayer) -> Bool {
        layer.bounds.width == 0 || layer.bounds.height == 0
    }

    /// Recursively compute the content bounding box of a layer's subtree.
    /// Group layers (zero bounds) are traversed to find leaf content (rects, shapes).
    static func contentBoundingBox(of layer: CALayer) -> CGRect {
        if let shapeLayer = layer as? CAShapeLayer, let path = shapeLayer.path {
            return path.boundingBoxOfPath
        }

        guard let sublayers = layer.sublayers, !sublayers.isEmpty else {
            return .null
        }

        return sublayers.reduce(CGRect.null) { result, sublayer in
            let childRect = sublayerContentRect(sublayer)
            guard !childRect.isNull else { return result }
            return result.union(childRect)
        }
    }

    private static func sublayerContentRect(_ layer: CALayer) -> CGRect {
        if let shapeLayer = layer as? CAShapeLayer, let path = shapeLayer.path {
            return path.boundingBoxOfPath
        }

        if layer.bounds.width > 0 || layer.bounds.height > 0 {
            return layer.frame
        }

        guard let sublayers = layer.sublayers, !sublayers.isEmpty else {
            return .null
        }

        var bbox = CGRect.null
        for sublayer in sublayers {
            let childRect = sublayerContentRect(sublayer)
            guard !childRect.isNull else { continue }
            bbox = bbox.union(childRect)
        }

        guard !bbox.isNull, !CATransform3DIsIdentity(layer.transform) else {
            return bbox
        }

        return transformedRect(bbox, by: layer.transform)
    }

    private static func transformedRect(_ rect: CGRect, by transform: CATransform3D) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]

        var result = CGRect.null
        for corner in corners {
            let x = transform.m11 * corner.x + transform.m21 * corner.y + transform.m41
            let y = transform.m12 * corner.x + transform.m22 * corner.y + transform.m42
            result = result.union(CGRect(x: x, y: y, width: 0, height: 0))
        }
        return result
    }
}
