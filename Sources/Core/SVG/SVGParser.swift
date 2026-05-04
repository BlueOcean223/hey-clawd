import Foundation
import CoreGraphics

/// SVG 解析入口。把原始 XML 文本拆解为 `SVGDocument`，再交给 CSSParser 解析样式块。
///
/// 实现细节：
/// - 使用 Foundation 的 `XMLParser`（SAX 风格）逐节点构建 `SVGNode` 树；
/// - 内联 `style="animation:..."` / `transition` 在 SVGDocument 构造完后做第二轮收集，
///   因为这一步需要知道完整的节点路径（nodePath）才能生成 InlineBinding；
/// - 不支持 `<text>`、`<filter>` 等节点——资产里没用到。
enum SVGParser {
    /// 单次 XML 解析的中间产物；CSSParser 会消费 `styleBlocks` 部分填补 animation/transition 字段。
    struct XMLResult: Sendable {
        var viewBox: SVGViewBox?
        var width: CGFloat?
        var height: CGFloat?
        var shapeRendering: String?
        var parseErrorDescription: String?
        var defsChildren: [SVGNode] = []
        var defs: [String: SVGNode] = [:]
        var rootChildren: [SVGNode] = []
        var styleBlocks: [String] = []
    }

    static func parseXML(_ svgString: String) -> XMLResult {
        guard !svgString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return XMLResult()
        }

        guard let data = svgString.data(using: .utf8) else {
            return XMLResult()
        }

        let delegate = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let description = parser.parserError?.localizedDescription ?? "Malformed SVG XML."
            logWarning("SVGParser: failed to parse XML (\(description))")
            return XMLResult(parseErrorDescription: description)
        }

        return delegate.result
    }

    /// 完整入口：XML → CSS → SVGDocument。两阶段是因为 inlineBinding 需要先有完整节点树。
    static func parse(_ svgString: String) -> SVGDocument {
        let xmlResult = parseXML(svgString)
        let cssResult = CSSParser.parse(xmlResult.styleBlocks)

        var document = SVGDocument(
            viewBox: xmlResult.viewBox,
            width: xmlResult.width,
            height: xmlResult.height,
            shapeRendering: xmlResult.shapeRendering,
            defsChildren: xmlResult.defsChildren,
            defs: xmlResult.defs,
            rootChildren: xmlResult.rootChildren,
            animations: cssResult.animations,
            staticStyleBindings: cssResult.staticStyleBindings,
            animationBindings: cssResult.animationBindings,
            animationStyleBindings: cssResult.animationStyleBindings,
            inlineAnimationBindings: [],
            transitions: cssResult.transitions,
            inlineTransitionBindings: []
        )

        document.inlineAnimationBindings = collectInlineAnimationBindings(in: document)
        document.inlineTransitionBindings = collectInlineTransitionBindings(in: document)
        validateUseReferences(in: document)
        return document
    }

    private static func validateUseReferences(in document: SVGDocument) {
        validateUseReferences(in: document.rootChildren, defs: document.defs)
        validateUseReferences(in: document.defsChildren, defs: document.defs)
    }

    private static func collectInlineAnimationBindings(in document: SVGDocument) -> [SVGInlineAnimationBinding] {
        collectInlineAnimationBindings(
            in: document.rootChildren,
            basePath: "root",
            document: document
        ) + collectInlineAnimationBindingsInDefs(in: document)
    }

    private static func collectInlineAnimationBindings(
        in nodes: [SVGNode],
        basePath: String,
        document: SVGDocument
    ) -> [SVGInlineAnimationBinding] {
        nodes.enumerated().flatMap { index, node in
            let nodePath = "\(basePath)/\(index)"
            let target = SVGNodeTarget(
                nodePath: nodePath,
                nodeID: node.nodeID,
                classes: node.classes
            )
            let inheritedBindings = inheritedAnimationBindings(for: node, in: document)
            let currentBindings = CSSParser.resolveInlineAnimationBindings(
                from: node.inlineStyles,
                inheritedBindings: inheritedBindings,
                target: target
            )
            return currentBindings + collectInlineAnimationBindings(in: node.childNodes, basePath: nodePath, document: document)
        }
    }

    private static func collectInlineAnimationBindingsInDefs(in document: SVGDocument) -> [SVGInlineAnimationBinding] {
        collectInlineAnimationBindings(in: document.defsChildren, basePath: "defs", document: document)
    }

    private static func collectInlineTransitionBindings(in document: SVGDocument) -> [SVGInlineTransitionBinding] {
        collectInlineTransitionBindings(
            in: document.rootChildren,
            basePath: "root",
            document: document
        ) + collectInlineTransitionBindingsInDefs(in: document)
    }

    private static func collectInlineTransitionBindings(
        in nodes: [SVGNode],
        basePath: String,
        document: SVGDocument
    ) -> [SVGInlineTransitionBinding] {
        nodes.enumerated().flatMap { index, node in
            let nodePath = "\(basePath)/\(index)"
            let target = SVGNodeTarget(
                nodePath: nodePath,
                nodeID: node.nodeID,
                classes: node.classes
            )
            let inheritedBindings = collapsedTransitionBindings(
                matchedBindings(from: document.transitions, node: node) { $0.selector }
            )
            let currentBindings = CSSParser.resolveInlineTransitionBindings(
                from: node.inlineStyles,
                inheritedBindings: inheritedBindings,
                target: target
            )
            return currentBindings + collectInlineTransitionBindings(in: node.childNodes, basePath: nodePath, document: document)
        }
    }

    private static func collectInlineTransitionBindingsInDefs(in document: SVGDocument) -> [SVGInlineTransitionBinding] {
        collectInlineTransitionBindings(in: document.defsChildren, basePath: "defs", document: document)
    }

    private static func matches(selector: CSSSelector, node: SVGNode) -> Bool {
        switch selector {
        case .className(let className):
            return node.classes.contains(className)
        case .id(let id):
            return node.nodeID == id
        }
    }

    private static func inheritedAnimationBindings(for node: SVGNode, in document: SVGDocument) -> [SVGAnimationBinding] {
        let directBindings = collapsedAnimationBindings(
            matchedBindings(from: document.animationBindings, node: node) { $0.selector }
        )
        let styleBindings = matchedBindings(from: document.animationStyleBindings, node: node) { $0.selector }
        guard !styleBindings.isEmpty else {
            return directBindings
        }

        var mergedBindings = directBindings
        var positionalStyleIndex = 0

        for styleBinding in styleBindings {
            if let animationName = styleBinding.animationName {
                if let index = mergedBindings.firstIndex(where: { $0.animationName == animationName }) {
                    mergedBindings[index] = merged(mergedBindings[index], with: styleBinding)
                } else {
                    mergedBindings.append(binding(from: styleBinding))
                }
                continue
            }

            if isPureTransformContext(styleBinding) {
                for index in mergedBindings.indices {
                    mergedBindings[index] = merged(mergedBindings[index], with: styleBinding)
                }
                continue
            }

            guard !mergedBindings.isEmpty else {
                mergedBindings.append(binding(from: styleBinding))
                continue
            }

            let targetIndex: Int
            if mergedBindings.count == 1 {
                targetIndex = 0
            } else {
                targetIndex = min(positionalStyleIndex, mergedBindings.count - 1)
                positionalStyleIndex += 1
            }

            mergedBindings[targetIndex] = merged(mergedBindings[targetIndex], with: styleBinding)
        }

        return mergedBindings
    }

    private static func isPureTransformContext(_ styleBinding: SVGAnimationStyleBinding) -> Bool {
        styleBinding.animationName == nil &&
            styleBinding.duration == nil &&
            styleBinding.timingFunction == nil &&
            styleBinding.iterationCount == nil &&
            styleBinding.direction == nil &&
            styleBinding.delay == nil &&
            styleBinding.fillMode == nil &&
            (styleBinding.transformOrigin != nil || styleBinding.transformBox != nil)
    }

    private static func binding(from styleBinding: SVGAnimationStyleBinding) -> SVGAnimationBinding {
        SVGAnimationBinding(
            selector: styleBinding.selector,
            animationName: styleBinding.animationName ?? "",
            duration: styleBinding.duration ?? 0,
            timingFunction: styleBinding.timingFunction ?? CSSParser.defaultTimingFunction,
            iterationCount: styleBinding.iterationCount ?? .count(1),
            direction: styleBinding.direction ?? .normal,
            delay: styleBinding.delay ?? 0,
            fillMode: styleBinding.fillMode ?? .none,
            transformOrigin: styleBinding.transformOrigin,
            transformBox: styleBinding.transformBox
        )
    }

    private static func matchedBindings<T>(
        from bindings: [T],
        node: SVGNode,
        selector: (T) -> CSSSelector
    ) -> [T] {
        bindings
            .enumerated()
            .filter { matches(selector: selector($0.element), node: node) }
            .sorted { lhs, rhs in
                let lhsSpecificity = selectorSpecificity(selector(lhs.element))
                let rhsSpecificity = selectorSpecificity(selector(rhs.element))
                if lhsSpecificity == rhsSpecificity {
                    return lhs.offset < rhs.offset
                }
                return lhsSpecificity < rhsSpecificity
            }
            .map(\.element)
    }

    private static func collapsedAnimationBindings(_ bindings: [SVGAnimationBinding]) -> [SVGAnimationBinding] {
        var collapsed: [SVGAnimationBinding] = []

        for binding in bindings {
            guard !binding.animationName.isEmpty else {
                collapsed.append(binding)
                continue
            }

            if let index = collapsed.firstIndex(where: { $0.animationName == binding.animationName }) {
                collapsed[index] = binding
            } else {
                collapsed.append(binding)
            }
        }

        return collapsed
    }

    private static func collapsedTransitionBindings(_ bindings: [SVGTransitionBinding]) -> [SVGTransitionBinding] {
        var collapsed: [SVGTransitionBinding] = []

        for binding in bindings {
            if let index = collapsed.firstIndex(where: { $0.property == binding.property }) {
                collapsed[index] = binding
            } else {
                collapsed.append(binding)
            }
        }

        return collapsed
    }

    private static func selectorSpecificity(_ selector: CSSSelector) -> Int {
        switch selector {
        case .className:
            return 0
        case .id:
            return 1
        }
    }

    private static func merged(_ binding: SVGAnimationBinding, with styleBinding: SVGAnimationStyleBinding) -> SVGAnimationBinding {
        SVGAnimationBinding(
            selector: binding.selector,
            animationName: styleBinding.animationName ?? binding.animationName,
            duration: styleBinding.duration ?? binding.duration,
            timingFunction: styleBinding.timingFunction ?? binding.timingFunction,
            iterationCount: styleBinding.iterationCount ?? binding.iterationCount,
            direction: styleBinding.direction ?? binding.direction,
            delay: styleBinding.delay ?? binding.delay,
            fillMode: styleBinding.fillMode ?? binding.fillMode,
            transformOrigin: styleBinding.transformOrigin ?? binding.transformOrigin,
            transformBox: styleBinding.transformBox ?? binding.transformBox
        )
    }

    private static func validateUseReferences(in nodes: [SVGNode], defs: [String: SVGNode]) {
        for node in nodes {
            validateUseReferences(in: node, defs: defs)
        }
    }

    private static func validateUseReferences(in node: SVGNode, defs: [String: SVGNode]) {
        switch node {
        case .group(let group):
            validateUseReferences(in: group.children, defs: defs)
        case .use(let use):
            validateUseReference(use, defs: defs)
        case .clipPath(let clipPath):
            validateUseReferences(in: clipPath.children, defs: defs)
        case .rect, .circle, .ellipse, .line, .path, .polygon, .polyline:
            return
        }
    }

    private static func validateUseReference(_ use: SVGUse, defs: [String: SVGNode]) {
        guard let targetID = referencedDefID(from: use.href) else {
            logWarning("SVGParser: <use> has an empty href\(use.id.map { " (id=\($0))" } ?? "").")
            return
        }

        guard defs[targetID] != nil else {
            logWarning("SVGParser: <use> references missing def '#\(targetID)'\(use.id.map { " (id=\($0))" } ?? "").")
            return
        }
    }

    private static func referencedDefID(from href: String) -> String? {
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

    private static func logWarning(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else {
            return
        }

        FileHandle.standardError.write(data)
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var result = SVGParser.XMLResult()

    private var stack: [ElementFrame] = []
    private var defsDepth = 0
    private var inDefs: Bool { defsDepth > 0 }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let kind = ElementKind(rawValue: normalizedName(elementName)) ?? .ignored
        let inheritedFill = stack.last?.activeFill
        let explicitFill = attributeValue(named: "fill", in: attributeDict)
        let activeFill = explicitFill ?? inheritedFill

        if kind == .svg {
            result.viewBox = parseViewBox(attributeValue(named: "viewBox", in: attributeDict))
            result.width = parseCGFloat(attributeValue(named: "width", in: attributeDict))
            result.height = parseCGFloat(attributeValue(named: "height", in: attributeDict))
            result.shapeRendering = attributeValue(named: "shape-rendering", in: attributeDict)
        } else if kind == .defs {
            defsDepth += 1
        }

        stack.append(
            ElementFrame(
                kind: kind,
                attributes: attributeDict,
                inheritedFill: inheritedFill,
                activeFill: activeFill
            )
        )
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        guard let frame = stack.popLast() else {
            return
        }

        if frame.kind == .style {
            result.styleBlocks.append(frame.textBuffer)
        }

        if frame.kind == .defs {
            defsDepth = max(0, defsDepth - 1)
            result.defsChildren.append(contentsOf: frame.children)
            return
        }

        if frame.kind == .svg {
            result.rootChildren = frame.children
            return
        }

        guard let node = buildNode(from: frame) else {
            return
        }

        let parentKind = stack.last?.kind
        if inDefs, parentKind == .defs {
            registerDefs(from: node)
            stack[stack.count - 1].children.append(node)
            return
        }

        guard !stack.isEmpty else {
            return
        }

        stack[stack.count - 1].children.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendStyleText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else {
            return
        }

        appendStyleText(string)
    }

    private func appendStyleText(_ string: String) {
        guard let index = stack.lastIndex(where: { $0.kind == .style }) else {
            return
        }

        stack[index].textBuffer += string
    }

    private func registerDefs(from node: SVGNode) {
        if let id = node.nodeID {
            result.defs[id] = node
        }

        for child in node.childNodes {
            registerDefs(from: child)
        }
    }

    private func buildNode(from frame: ElementFrame) -> SVGNode? {
        let common = commonAttributes(from: frame.attributes)
        let fill = attributeValue(named: "fill", in: frame.attributes) ?? frame.inheritedFill

        switch frame.kind {
        case .group:
            return .group(
                SVGGroup(
                    id: common.id,
                    classes: common.classes,
                    inlineStyles: common.inlineStyles,
                    clipPathRef: common.clipPathRef,
                    fill: fill,
                    stroke: attributeValue(named: "stroke", in: frame.attributes),
                    strokeWidth: parseCGFloat(attributeValue(named: "stroke-width", in: frame.attributes)),
                    strokeLinecap: attributeValue(named: "stroke-linecap", in: frame.attributes),
                    strokeLinejoin: attributeValue(named: "stroke-linejoin", in: frame.attributes),
                    opacity: parseCGFloat(attributeValue(named: "opacity", in: frame.attributes)),
                    transform: attributeValue(named: "transform", in: frame.attributes),
                    children: frame.children
                )
            )
        case .rect:
            return .rect(
                SVGRect(
                    id: common.id,
                    classes: common.classes,
                    inlineStyles: common.inlineStyles,
                    clipPathRef: common.clipPathRef,
                    x: parseCGFloat(attributeValue(named: "x", in: frame.attributes)),
                    y: parseCGFloat(attributeValue(named: "y", in: frame.attributes)),
                    width: parseCGFloat(attributeValue(named: "width", in: frame.attributes)),
                    height: parseCGFloat(attributeValue(named: "height", in: frame.attributes)),
                    rx: parseCGFloat(attributeValue(named: "rx", in: frame.attributes)),
                    ry: parseCGFloat(attributeValue(named: "ry", in: frame.attributes)),
                    transform: attributeValue(named: "transform", in: frame.attributes),
                    fill: fill,
                    stroke: attributeValue(named: "stroke", in: frame.attributes),
                    strokeWidth: parseCGFloat(attributeValue(named: "stroke-width", in: frame.attributes)),
                    opacity: parseCGFloat(attributeValue(named: "opacity", in: frame.attributes))
                )
            )
        case .use:
            guard let href = attributeValue(named: "href", in: frame.attributes)
                ?? frame.attributes["xlink:href"]
            else {
                return nil
            }

            return .use(
                SVGUse(
                    id: common.id,
                    classes: common.classes,
                    inlineStyles: common.inlineStyles,
                    clipPathRef: common.clipPathRef,
                    href: href,
                    transform: attributeValue(named: "transform", in: frame.attributes),
                    fill: fill,
                    stroke: attributeValue(named: "stroke", in: frame.attributes),
                    strokeWidth: parseCGFloat(attributeValue(named: "stroke-width", in: frame.attributes)),
                    strokeLinecap: attributeValue(named: "stroke-linecap", in: frame.attributes),
                    strokeLinejoin: attributeValue(named: "stroke-linejoin", in: frame.attributes),
                    x: parseCGFloat(attributeValue(named: "x", in: frame.attributes)),
                    y: parseCGFloat(attributeValue(named: "y", in: frame.attributes))
                )
            )
        case .circle:
            return .circle(
                SVGCircle(
                    id: common.id,
                    classes: common.classes,
                    inlineStyles: common.inlineStyles,
                    clipPathRef: common.clipPathRef,
                    cx: parseCGFloat(attributeValue(named: "cx", in: frame.attributes)),
                    cy: parseCGFloat(attributeValue(named: "cy", in: frame.attributes)),
                    r: parseCGFloat(attributeValue(named: "r", in: frame.attributes)),
                    fill: fill,
                    stroke: attributeValue(named: "stroke", in: frame.attributes),
                    strokeWidth: parseCGFloat(attributeValue(named: "stroke-width", in: frame.attributes)),
                    strokeLinecap: attributeValue(named: "stroke-linecap", in: frame.attributes),
                    strokeLinejoin: attributeValue(named: "stroke-linejoin", in: frame.attributes),
                    opacity: parseCGFloat(attributeValue(named: "opacity", in: frame.attributes))
                )
            )
        case .ellipse:
            return .ellipse(
                SVGEllipse(
                    id: common.id,
                    classes: common.classes,
                    inlineStyles: common.inlineStyles,
                    clipPathRef: common.clipPathRef,
                    cx: parseCGFloat(attributeValue(named: "cx", in: frame.attributes)),
                    cy: parseCGFloat(attributeValue(named: "cy", in: frame.attributes)),
                    rx: parseCGFloat(attributeValue(named: "rx", in: frame.attributes)),
                    ry: parseCGFloat(attributeValue(named: "ry", in: frame.attributes)),
                    fill: fill,
                    stroke: attributeValue(named: "stroke", in: frame.attributes),
                    strokeWidth: parseCGFloat(attributeValue(named: "stroke-width", in: frame.attributes)),
                    strokeLinecap: attributeValue(named: "stroke-linecap", in: frame.attributes),
                    strokeLinejoin: attributeValue(named: "stroke-linejoin", in: frame.attributes),
                    opacity: parseCGFloat(attributeValue(named: "opacity", in: frame.attributes))
                )
            )
        case .line:
            return .line(
                SVGLine(
                    id: common.id,
                    classes: common.classes,
                    inlineStyles: common.inlineStyles,
                    clipPathRef: common.clipPathRef,
                    x1: parseCGFloat(attributeValue(named: "x1", in: frame.attributes)),
                    y1: parseCGFloat(attributeValue(named: "y1", in: frame.attributes)),
                    x2: parseCGFloat(attributeValue(named: "x2", in: frame.attributes)),
                    y2: parseCGFloat(attributeValue(named: "y2", in: frame.attributes)),
                    stroke: attributeValue(named: "stroke", in: frame.attributes),
                    strokeWidth: parseCGFloat(attributeValue(named: "stroke-width", in: frame.attributes)),
                    strokeLinecap: attributeValue(named: "stroke-linecap", in: frame.attributes)
                )
            )
        case .path:
            guard let d = attributeValue(named: "d", in: frame.attributes) else {
                return nil
            }

            return .path(
                SVGPath(
                    id: common.id,
                    classes: common.classes,
                    inlineStyles: common.inlineStyles,
                    clipPathRef: common.clipPathRef,
                    d: d,
                    fill: fill,
                    stroke: attributeValue(named: "stroke", in: frame.attributes),
                    strokeWidth: parseCGFloat(attributeValue(named: "stroke-width", in: frame.attributes)),
                    strokeLinecap: attributeValue(named: "stroke-linecap", in: frame.attributes),
                    strokeLinejoin: attributeValue(named: "stroke-linejoin", in: frame.attributes)
                )
            )
        case .polygon:
            guard let points = attributeValue(named: "points", in: frame.attributes) else {
                return nil
            }

            return .polygon(
                SVGPolygon(
                    id: common.id,
                    classes: common.classes,
                    inlineStyles: common.inlineStyles,
                    clipPathRef: common.clipPathRef,
                    points: points,
                    fill: fill,
                    stroke: attributeValue(named: "stroke", in: frame.attributes),
                    strokeWidth: parseCGFloat(attributeValue(named: "stroke-width", in: frame.attributes)),
                    strokeLinecap: attributeValue(named: "stroke-linecap", in: frame.attributes),
                    strokeLinejoin: attributeValue(named: "stroke-linejoin", in: frame.attributes),
                    opacity: parseCGFloat(attributeValue(named: "opacity", in: frame.attributes))
                )
            )
        case .polyline:
            guard let points = attributeValue(named: "points", in: frame.attributes) else {
                return nil
            }

            return .polyline(
                SVGPolyline(
                    id: common.id,
                    classes: common.classes,
                    inlineStyles: common.inlineStyles,
                    clipPathRef: common.clipPathRef,
                    points: points,
                    fill: fill,
                    stroke: attributeValue(named: "stroke", in: frame.attributes),
                    strokeWidth: parseCGFloat(attributeValue(named: "stroke-width", in: frame.attributes)),
                    strokeLinecap: attributeValue(named: "stroke-linecap", in: frame.attributes),
                    strokeLinejoin: attributeValue(named: "stroke-linejoin", in: frame.attributes)
                )
            )
        case .clipPath:
            guard let id = common.id else {
                return nil
            }

            return .clipPath(
                SVGClipPathDef(
                    id: id,
                    classes: common.classes,
                    inlineStyles: common.inlineStyles,
                    clipPathRef: common.clipPathRef,
                    children: frame.children
                )
            )
        case .svg, .defs, .style, .ignored:
            return nil
        }
    }
}

private extension XMLTreeBuilder {
    struct CommonAttributes {
        var id: String?
        var classes: [String]
        var inlineStyles: [String: String]
        var clipPathRef: String?
    }

    struct ElementFrame {
        var kind: ElementKind
        var attributes: [String: String]
        var children: [SVGNode] = []
        var inheritedFill: String?
        var activeFill: String?
        var textBuffer = ""
    }

    enum ElementKind: String {
        case svg
        case defs
        case group = "g"
        case rect
        case use
        case circle
        case ellipse
        case line
        case path
        case polygon
        case polyline
        case clipPath = "clippath"
        case style
        case ignored
    }

    func commonAttributes(from attributes: [String: String]) -> CommonAttributes {
        var inlineStyles = parseInlineStyles(attributeValue(named: "style", in: attributes))
        if let shapeRendering = attributeValue(named: "shape-rendering", in: attributes) {
            inlineStyles["shape-rendering"] = shapeRendering
        }

        return CommonAttributes(
            id: attributeValue(named: "id", in: attributes),
            classes: parseClasses(attributeValue(named: "class", in: attributes)),
            inlineStyles: inlineStyles,
            clipPathRef: parseClipPathReference(attributeValue(named: "clip-path", in: attributes))
        )
    }

    func parseInlineStyles(_ rawValue: String?) -> [String: String] {
        guard let rawValue else {
            return [:]
        }
        return CSSParser.parseInlineDeclarations(rawValue)
    }

    func parseClasses(_ rawValue: String?) -> [String] {
        guard let rawValue else {
            return []
        }

        return rawValue
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    func parseClipPathReference(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("url(#"), trimmed.hasSuffix(")") else {
            return nil
        }

        let start = trimmed.index(trimmed.startIndex, offsetBy: 5)
        let end = trimmed.index(before: trimmed.endIndex)
        let id = String(trimmed[start..<end])
        return id.isEmpty ? nil : id
    }

    func parseViewBox(_ rawValue: String?) -> SVGViewBox? {
        guard let rawValue else {
            return nil
        }

        let components = rawValue
            .components(separatedBy: CharacterSet(charactersIn: ", \n\r\t"))
            .filter { !$0.isEmpty }

        guard components.count == 4,
              let x = parseCGFloat(components[0]),
              let y = parseCGFloat(components[1]),
              let width = parseCGFloat(components[2]),
              let height = parseCGFloat(components[3]) else {
            return nil
        }

        return SVGViewBox(x: x, y: y, width: width, height: height)
    }

    func parseCGFloat(_ rawValue: String?) -> CGFloat? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let normalized = trimmed.lowercased()
        let numberPortion: String
        if normalized.hasSuffix("px") {
            numberPortion = String(normalized.dropLast(2))
        } else if normalized.hasSuffix("%") {
            numberPortion = String(normalized.dropLast())
        } else {
            numberPortion = normalized
        }

        guard let value = Double(numberPortion.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return CGFloat(value)
    }

    func attributeValue(named name: String, in attributes: [String: String]) -> String? {
        if let direct = attributes[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !direct.isEmpty {
            return direct
        }

        let wantedName = normalizedName(name)
        for (key, value) in attributes {
            guard normalizedName(key) == wantedName else {
                continue
            }

            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    func normalizedName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }
}

private extension SVGNode {
    var nodeID: String? {
        switch self {
        case .group(let group):
            return group.id
        case .rect(let rect):
            return rect.id
        case .use(let use):
            return use.id
        case .circle(let circle):
            return circle.id
        case .ellipse(let ellipse):
            return ellipse.id
        case .line(let line):
            return line.id
        case .path(let path):
            return path.id
        case .polygon(let polygon):
            return polygon.id
        case .polyline(let polyline):
            return polyline.id
        case .clipPath(let clipPath):
            return clipPath.id
        }
    }

    var classes: [String] {
        switch self {
        case .group(let group):
            return group.classes
        case .rect(let rect):
            return rect.classes
        case .use(let use):
            return use.classes
        case .circle(let circle):
            return circle.classes
        case .ellipse(let ellipse):
            return ellipse.classes
        case .line(let line):
            return line.classes
        case .path(let path):
            return path.classes
        case .polygon(let polygon):
            return polygon.classes
        case .polyline(let polyline):
            return polyline.classes
        case .clipPath(let clipPath):
            return clipPath.classes
        }
    }

    var inlineStyles: [String: String] {
        switch self {
        case .group(let group):
            return group.inlineStyles
        case .rect(let rect):
            return rect.inlineStyles
        case .use(let use):
            return use.inlineStyles
        case .circle(let circle):
            return circle.inlineStyles
        case .ellipse(let ellipse):
            return ellipse.inlineStyles
        case .line(let line):
            return line.inlineStyles
        case .path(let path):
            return path.inlineStyles
        case .polygon(let polygon):
            return polygon.inlineStyles
        case .polyline(let polyline):
            return polyline.inlineStyles
        case .clipPath(let clipPath):
            return clipPath.inlineStyles
        }
    }

    var childNodes: [SVGNode] {
        switch self {
        case .group(let group):
            return group.children
        case .clipPath(let clipPath):
            return clipPath.children
        case .rect, .use, .circle, .ellipse, .line, .path, .polygon, .polyline:
            return []
        }
    }
}
