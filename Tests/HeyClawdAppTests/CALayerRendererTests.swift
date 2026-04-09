import Foundation
import CoreGraphics
import QuartzCore
import XCTest
@testable import HeyClawdApp

@MainActor
final class CALayerRendererTests: XCTestCase {
    private static var projectRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    private func loadSVG(_ name: String) throws -> String {
        let path = Self.projectRoot + "/Resources/svg/\(name).svg"
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    @MainActor
    func testBuildCreatesExpectedLayerTreeForIdleFollowSVG() throws {
        let svg = try loadSVG("clawd-idle-follow")
        let document = SVGParser.parse(svg)

        let rootLayer = CALayerRenderer.build(document)

        XCTAssertEqual(rootLayer.bounds, CGRect(x: 0, y: 0, width: 45, height: 45))
        XCTAssertEqual(rootLayer.sublayerTransform.m41, 15, accuracy: 0.01)
        XCTAssertEqual(rootLayer.sublayerTransform.m42, 25, accuracy: 0.01)
        XCTAssertEqual(rootLayer.sublayers?.count, document.rootChildren.count)
        XCTAssertNotNil(findLayer(named: "legs", in: rootLayer))
    }

    @MainActor
    func testBuildPositionsRectLayersPrecisely() throws {
        let document = SVGParser.parse(
            """
            <svg viewBox="0 0 15 16" xmlns="http://www.w3.org/2000/svg">
              <rect id="torso" x="2" y="6" width="11" height="7" fill="#DE886D"/>
            </svg>
            """
        )

        let rootLayer = CALayerRenderer.build(document)
        let rectLayer = try XCTUnwrap(findLayer(named: "torso", in: rootLayer))

        XCTAssertEqual(rectLayer.position.x, 7.5, accuracy: 0.01)
        XCTAssertEqual(rectLayer.position.y, 9.5, accuracy: 0.01)
        XCTAssertEqual(rectLayer.bounds, CGRect(x: 0, y: 0, width: 11, height: 7))
        assertColorApprox(rectLayer.backgroundColor, red: 0.87, green: 0.53, blue: 0.43, alpha: 1.0)
    }

    @MainActor
    func testBuildCreatesShapeLayersForCircleEllipseAndLine() throws {
        let document = SVGParser.parse(
            """
            <svg viewBox="0 0 50 50" xmlns="http://www.w3.org/2000/svg">
              <circle id="c1" cx="10" cy="10" r="5" fill="#FF5252"/>
              <ellipse id="e1" cx="25" cy="25" rx="8" ry="4" fill="#000"/>
              <line id="l1" x1="0" y1="0" x2="50" y2="50" stroke="#FFF" stroke-width="2"/>
            </svg>
            """
        )

        let rootLayer = CALayerRenderer.build(document)

        let circleLayer = try XCTUnwrap(findLayer(named: "c1", in: rootLayer) as? CAShapeLayer)
        XCTAssertNotNil(circleLayer.path)
        XCTAssertNotNil(circleLayer.fillColor)

        let ellipseLayer = try XCTUnwrap(findLayer(named: "e1", in: rootLayer) as? CAShapeLayer)
        XCTAssertNotNil(ellipseLayer.path)
        XCTAssertNotNil(ellipseLayer.fillColor)

        let lineLayer = try XCTUnwrap(findLayer(named: "l1", in: rootLayer) as? CAShapeLayer)
        XCTAssertNotNil(lineLayer.path)
        XCTAssertNil(lineLayer.fillColor)
        XCTAssertNotNil(lineLayer.strokeColor)
        XCTAssertEqual(lineLayer.lineWidth, 2, accuracy: 0.01)
    }

    @MainActor
    func testColorParserHandlesHexRGBAAndNoneValues() {
        assertColorApprox(ColorParser.parse("#DE886D"), red: 0.87, green: 0.53, blue: 0.43, alpha: 1.0)
        assertColorApprox(ColorParser.parse("#000"), red: 0, green: 0, blue: 0, alpha: 1.0)
        assertColorApprox(ColorParser.parse("none"), red: 0, green: 0, blue: 0, alpha: 0)
        assertColorApprox(ColorParser.parse("#FFFFFF80"), red: 1, green: 1, blue: 1, alpha: 0.50)
        assertColorApprox(ColorParser.parse("rgba(0,0,0,0.15)"), red: 0, green: 0, blue: 0, alpha: 0.15)
        XCTAssertNil(ColorParser.parse(nil))
        XCTAssertNil(ColorParser.parse(""))
    }

    @MainActor
    func testPathParserHandlesPathsPolygonsAndPolylines() throws {
        XCTAssertNotNil(PathParser.parsePath("M4,3 Q5,1 6,3"))
        XCTAssertNil(PathParser.parsePath(""))

        let polygon = try XCTUnwrap(PathParser.parsePolygonPoints("4,8 5.5,9 4,10"))
        XCTAssertTrue(polygon.contains(CGPoint(x: 4.5, y: 9), using: .winding, transform: .identity))

        XCTAssertNotNil(PathParser.parsePolylinePoints("4,8 5.5,9 4,10"))
    }

    @MainActor
    func testBuildAppliesClipPathAsMask() throws {
        let document = SVGParser.parse(
            """
            <svg viewBox="0 0 45 45" xmlns="http://www.w3.org/2000/svg">
              <defs>
                <clipPath id="ground-clip">
                  <rect x="-15" y="-25" width="45" height="40"/>
                </clipPath>
              </defs>
              <g clip-path="url(#ground-clip)">
                <rect x="2" y="6" width="11" height="7" fill="#DE886D"/>
              </g>
            </svg>
            """
        )

        let rootLayer = CALayerRenderer.build(document)
        let groupLayer = try XCTUnwrap(rootLayer.sublayers?.first)
        let maskLayer = try XCTUnwrap(groupLayer.mask)

        XCTAssertNotNil(groupLayer.mask)
        XCTAssertFalse(maskLayer.sublayers?.isEmpty ?? true)
    }

    @MainActor
    func testBuildAdjustsAnchorPointFromTransformOrigin() throws {
        let document = SVGParser.parse(
            """
            <svg viewBox="0 0 15 16" xmlns="http://www.w3.org/2000/svg">
              <defs><style>.breathe { transform-origin: 7.5px 13px; }</style></defs>
              <g class="breathe">
                <rect x="2" y="6" width="11" height="7" fill="#DE886D"/>
              </g>
            </svg>
            """
        )

        let rootLayer = CALayerRenderer.build(document)
        let groupLayer = try XCTUnwrap(findLayer(withClass: "breathe", in: rootLayer))

        XCTAssertNotEqual(groupLayer.anchorPoint.x, 0.5, accuracy: 0.01)
        XCTAssertNotEqual(groupLayer.anchorPoint.y, 0.5, accuracy: 0.01)
        XCTAssertEqual(groupLayer.value(forKey: "svgTransformOrigin") as? String, "7.5px 13px")
    }

    @MainActor
    func testBuildInheritsParentFillAndAllowsOverrides() throws {
        let document = SVGParser.parse(
            """
            <svg viewBox="0 0 15 16" xmlns="http://www.w3.org/2000/svg">
              <g fill="#DE886D">
                <rect id="r1" x="0" y="0" width="5" height="5"/>
                <rect id="r2" x="5" y="0" width="5" height="5" fill="#000000"/>
              </g>
            </svg>
            """
        )

        let rootLayer = CALayerRenderer.build(document)
        let r1Layer = try XCTUnwrap(findLayer(named: "r1", in: rootLayer))
        let r2Layer = try XCTUnwrap(findLayer(named: "r2", in: rootLayer))

        assertColorApprox(r1Layer.backgroundColor, red: 0.87, green: 0.53, blue: 0.43, alpha: 1.0)
        assertColorApprox(r2Layer.backgroundColor, red: 0, green: 0, blue: 0, alpha: 1.0)
    }

    @MainActor
    func testHitTestMatchesRectGeometry() throws {
        let document = SVGParser.parse(
            """
            <svg viewBox="0 0 15 16" xmlns="http://www.w3.org/2000/svg">
              <rect x="2" y="6" width="11" height="7" fill="#DE886D"/>
            </svg>
            """
        )

        let rootLayer = CALayerRenderer.build(document)

        XCTAssertTrue(CALayerRenderer.hitTest(point: CGPoint(x: 7, y: 9), in: rootLayer))
        XCTAssertFalse(CALayerRenderer.hitTest(point: CGPoint(x: 0, y: 0), in: rootLayer))
        XCTAssertFalse(CALayerRenderer.hitTest(point: CGPoint(x: 14, y: 15), in: rootLayer))
    }

    @MainActor
    func testBuildNegatesNegativeViewBoxOffsetIntoSublayerTransform() throws {
        let document = SVGParser.parse(
            """
            <svg viewBox="-15 -25 45 45" xmlns="http://www.w3.org/2000/svg">
              <rect x="2" y="6" width="11" height="7" fill="#DE886D"/>
            </svg>
            """
        )

        let rootLayer = CALayerRenderer.build(document)

        XCTAssertEqual(rootLayer.sublayerTransform.m41, 15, accuracy: 0.01)
        XCTAssertEqual(rootLayer.sublayerTransform.m42, 25, accuracy: 0.01)
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

    private func assertColorApprox(
        _ color: CGColor?,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat,
        accuracy: CGFloat = 0.01,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let components = try? XCTUnwrap(color?.components, file: file, line: line) else {
            XCTFail("Expected color components.", file: file, line: line)
            return
        }

        XCTAssertEqual(components.count, 4, file: file, line: line)
        XCTAssertEqual(components[0], red, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(components[1], green, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(components[2], blue, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(components[3], alpha, accuracy: accuracy, file: file, line: line)
    }
}
