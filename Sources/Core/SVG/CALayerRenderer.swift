import AppKit
import QuartzCore

@MainActor
enum CALayerRenderer {
    static func build(_ document: SVGDocument) -> CALayer {
        let rootLayer = makeLayer()
        rootLayer.bounds = rootBounds(for: document)
        rootLayer.masksToBounds = true

        if let viewBox = document.viewBox,
           viewBox.x != 0 || viewBox.y != 0 {
            rootLayer.sublayerTransform = CATransform3DMakeTranslation(-viewBox.x, -viewBox.y, 0)
        }

        if document.shapeRendering == "crispEdges" {
            rootLayer.shouldRasterize = true
            rootLayer.rasterizationScale = rootLayer.contentsScale
            rootLayer.edgeAntialiasingMask = []
        }

        for (index, node) in document.rootChildren.enumerated() {
            let nodePath = "root/\(index)"
            guard let layer = buildLayer(
                for: node,
                inheritedFill: nil,
                document: document,
                nodePath: nodePath
            ) else {
                continue
            }

            rootLayer.addSublayer(layer)
        }

        return rootLayer
    }

    private static func buildLayer(
        for node: SVGNode,
        inheritedFill: String?,
        document: SVGDocument,
        nodePath: String
    ) -> CALayer? {
        switch node {
        case .group(let group):
            let layer = makeLayer()
            layer.name = group.id
            storeMetadata(on: layer, nodePath: nodePath, classes: group.classes)

            if let opacity = group.opacity {
                layer.opacity = Float(opacity)
            }

            let childFill = group.fill ?? inheritedFill
            for (index, childNode) in group.children.enumerated() {
                let childPath = "\(nodePath)/\(index)"
                guard let childLayer = buildLayer(
                    for: childNode,
                    inheritedFill: childFill,
                    document: document,
                    nodePath: childPath
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

            let strokeColor = ColorParser.parse(rect.stroke)
            layer.borderColor = strokeColor
            layer.borderWidth = resolvedLineWidth(strokeColor: strokeColor, strokeWidth: rect.strokeWidth)
            layer.cornerRadius = resolvedCornerRadius(rx: rect.rx, ry: rect.ry)
            layer.opacity = rect.opacity.map(Float.init) ?? layer.opacity
            layer.name = rect.id

            storeMetadata(on: layer, nodePath: nodePath, classes: rect.classes)
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
            let strokeColor = ColorParser.parse(circle.stroke)
            layer.strokeColor = strokeColor
            layer.lineWidth = resolvedLineWidth(strokeColor: strokeColor, strokeWidth: circle.strokeWidth)
            layer.opacity = circle.opacity.map(Float.init) ?? layer.opacity
            layer.name = circle.id

            storeMetadata(on: layer, nodePath: nodePath, classes: circle.classes)
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
            layer.opacity = ellipse.opacity.map(Float.init) ?? layer.opacity
            layer.name = ellipse.id

            storeMetadata(on: layer, nodePath: nodePath, classes: ellipse.classes)
            applyInlineStyles(ellipse.inlineStyles, to: layer, hasExplicitOpacity: ellipse.opacity != nil)
            applyClipPath(ellipse.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .line(let line):
            let layer = makeShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: line.x1 ?? 0, y: line.y1 ?? 0))
            path.addLine(to: CGPoint(x: line.x2 ?? 0, y: line.y2 ?? 0))

            let strokeColor = ColorParser.parse(line.stroke)
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = strokeColor
            layer.lineWidth = resolvedLineWidth(strokeColor: strokeColor, strokeWidth: line.strokeWidth)
            layer.lineCap = lineCap(for: line.strokeLinecap)
            layer.name = line.id

            storeMetadata(on: layer, nodePath: nodePath, classes: line.classes)
            applyInlineStyles(line.inlineStyles, to: layer, hasExplicitOpacity: false)
            applyClipPath(line.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .path(let path):
            guard let cgPath = PathParser.parsePath(path.d) else {
                return nil
            }

            let layer = makeShapeLayer()
            let strokeColor = ColorParser.parse(path.stroke)

            layer.path = cgPath
            layer.fillColor = ColorParser.parse(path.fill ?? inheritedFill)
            layer.strokeColor = strokeColor
            layer.lineWidth = resolvedLineWidth(strokeColor: strokeColor, strokeWidth: path.strokeWidth)
            layer.lineJoin = lineJoin(for: path.strokeLinejoin)
            layer.name = path.id

            storeMetadata(on: layer, nodePath: nodePath, classes: path.classes)
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
            layer.opacity = polygon.opacity.map(Float.init) ?? layer.opacity
            layer.name = polygon.id

            storeMetadata(on: layer, nodePath: nodePath, classes: polygon.classes)
            applyInlineStyles(polygon.inlineStyles, to: layer, hasExplicitOpacity: polygon.opacity != nil)
            applyClipPath(polygon.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .polyline(let polyline):
            guard let cgPath = PathParser.parsePolylinePoints(polyline.points) else {
                return nil
            }

            let layer = makeShapeLayer()
            let strokeColor = ColorParser.parse(polyline.stroke)

            layer.path = cgPath
            layer.fillColor = ColorParser.parse(polyline.fill ?? inheritedFill)
            layer.strokeColor = strokeColor
            layer.lineWidth = resolvedLineWidth(strokeColor: strokeColor, strokeWidth: polyline.strokeWidth)
            layer.lineCap = lineCap(for: polyline.strokeLinecap)
            layer.lineJoin = lineJoin(for: polyline.strokeLinejoin)
            layer.name = polyline.id

            storeMetadata(on: layer, nodePath: nodePath, classes: polyline.classes)
            applyInlineStyles(polyline.inlineStyles, to: layer, hasExplicitOpacity: false)
            applyClipPath(polyline.clipPathRef, to: layer, document: document, nodePath: nodePath)
            return layer

        case .use(let use):
            guard let referencedNode = document.referencedNode(for: use) else {
                return nil
            }

            let layer = buildLayer(
                for: referencedNode,
                inheritedFill: use.fill ?? inheritedFill,
                document: document,
                nodePath: nodePath
            ) ?? makeLayer()

            if let x = use.x, x != 0 {
                layer.transform = CATransform3DTranslate(layer.transform, x, 0, 0)
            }

            if let y = use.y, y != 0 {
                layer.transform = CATransform3DTranslate(layer.transform, 0, y, 0)
            }

            layer.name = use.id
            storeMetadata(on: layer, nodePath: nodePath, classes: use.classes)
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
                    document: document,
                    nodePath: childPath
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

        for binding in matchedBindings {
            if let transformOrigin = binding.properties["transform-origin"] {
                layer.setValue(transformOrigin, forKey: "svgTransformOrigin")
                applyTransformOrigin(transformOrigin, to: layer)
            }

            if let transformBox = binding.properties["transform-box"] {
                layer.setValue(transformBox, forKey: "svgTransformBox")
            }
        }
    }

    static func applyTransformOrigin(_ rawValue: String, to layer: CALayer) {
        guard let origin = CSSParser.resolvedTransformOrigin(from: rawValue) else {
            return
        }

        setAnchorPoint(origin, on: layer)
    }

    static func setAnchorPoint(_ origin: SVGTransformOrigin, on layer: CALayer) {
        let oldAnchorPoint = layer.anchorPoint

        if needsBoundingBox(for: origin, on: layer) {
            let bbox = layer.sublayers?.reduce(CGRect.null) { partialResult, sublayer in
                partialResult.union(sublayer.frame)
            } ?? .null

            if !bbox.isNull, !bbox.isEmpty {
                layer.bounds = bbox
                layer.position = CGPoint(
                    x: bbox.minX + (oldAnchorPoint.x * bbox.width),
                    y: bbox.minY + (oldAnchorPoint.y * bbox.height)
                )
            }
        }

        let bounds = layer.bounds
        var newAnchorPoint = oldAnchorPoint

        if bounds.width != 0 {
            switch origin.x {
            case .px(let value):
                newAnchorPoint.x = value / bounds.width
            case .percent(let value):
                newAnchorPoint.x = value / 100
            }
        }

        if bounds.height != 0 {
            switch origin.y {
            case .px(let value):
                newAnchorPoint.y = value / bounds.height
            case .percent(let value):
                newAnchorPoint.y = value / 100
            }
        }

        let dx = (newAnchorPoint.x - oldAnchorPoint.x) * bounds.width
        let dy = (newAnchorPoint.y - oldAnchorPoint.y) * bounds.height

        layer.anchorPoint = newAnchorPoint
        layer.position = CGPoint(x: layer.position.x + dx, y: layer.position.y + dy)
    }

    static func needsBoundingBox(for origin: SVGTransformOrigin, on layer: CALayer) -> Bool {
        let widthNeedsBBox: Bool
        switch origin.x {
        case .px:
            widthNeedsBBox = layer.bounds.width == 0
        case .percent:
            widthNeedsBBox = false
        }

        let heightNeedsBBox: Bool
        switch origin.y {
        case .px:
            heightNeedsBBox = layer.bounds.height == 0
        case .percent:
            heightNeedsBBox = false
        }

        return widthNeedsBBox || heightNeedsBBox
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
                document: document,
                nodePath: "\(nodePath)/clipPath"
              ) else {
            return
        }

        layer.mask = maskLayer
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
}
