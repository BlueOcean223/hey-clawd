import Foundation
import CoreGraphics

enum SVGParser {
    struct XMLResult: Sendable {
        var viewBox: SVGViewBox?
        var width: CGFloat?
        var height: CGFloat?
        var defs: [String: SVGNode] = [:]
        var rootChildren: [SVGNode] = []
        var styleBlocks: [String] = []
    }

    static func parseXML(_ svgString: String) -> XMLResult {
        guard let data = svgString.data(using: .utf8) else {
            return XMLResult()
        }

        let delegate = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    static func parse(_ svgString: String) -> SVGDocument {
        let xmlResult = parseXML(svgString)
        let cssResult = CSSParser.parse(xmlResult.styleBlocks)

        let document = SVGDocument(
            viewBox: xmlResult.viewBox,
            width: xmlResult.width,
            height: xmlResult.height,
            defs: xmlResult.defs,
            rootChildren: xmlResult.rootChildren,
            animations: cssResult.animations,
            animationBindings: cssResult.animationBindings,
            transitions: cssResult.transitions
        )

        validateUseReferences(in: document)
        return document
    }

    private static func validateUseReferences(in document: SVGDocument) {
        validateUseReferences(in: document.rootChildren, defs: document.defs)
        validateUseReferences(in: Array(document.defs.values), defs: document.defs)
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
            if let id = node.nodeID {
                result.defs[id] = node
            }
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
                    fill: fill,
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
                    fill: fill,
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
        case clipPath
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

        var styles: [String: String] = [:]
        for declaration in rawValue.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = declaration.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }

            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                continue
            }

            styles[key] = value
        }

        return styles
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
        guard let value = Double(trimmed) else {
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
}
