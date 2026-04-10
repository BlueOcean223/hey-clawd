import Foundation
import CoreGraphics
import XCTest
@testable import HeyClawdApp

final class SVGParserTests: XCTestCase {
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

    func testParseParsesBasicRectGroupAndUseWithInheritedFill() throws {
        let document = SVGParser.parse(
            """
            <svg viewBox="0 0 120 80" width="120" height="80" xmlns="http://www.w3.org/2000/svg">
              <defs>
                <rect id="body" x="4" y="6" width="40" height="20" />
              </defs>
              <g id="root" class="idle follow" fill="#112233">
                <g id="layer" class="body-layer">
                  <rect id="panel" x="10" y="12" width="16" height="8" />
                  <use id="body-use" href="#body" x="2" y="3" />
                </g>
              </g>
            </svg>
            """
        )

        let viewBox = try XCTUnwrap(document.viewBox)
        XCTAssertEqual(viewBox.x, 0)
        XCTAssertEqual(viewBox.y, 0)
        XCTAssertEqual(viewBox.width, 120)
        XCTAssertEqual(viewBox.height, 80)
        XCTAssertEqual(document.width, 120)
        XCTAssertEqual(document.height, 80)
        XCTAssertEqual(document.defs.count, 1)
        XCTAssertEqual(document.rootChildren.count, 1)

        let defRect = try rectNode(from: try XCTUnwrap(document.defs["body"]))
        XCTAssertEqual(defRect.id, "body")
        XCTAssertEqual(defRect.x, 4)
        XCTAssertEqual(defRect.y, 6)
        XCTAssertEqual(defRect.width, 40)
        XCTAssertEqual(defRect.height, 20)
        XCTAssertNil(defRect.fill)

        let rootGroup = try groupNode(from: document.rootChildren[0])
        XCTAssertEqual(rootGroup.id, "root")
        XCTAssertEqual(rootGroup.classes, ["idle", "follow"])
        XCTAssertEqual(rootGroup.fill, "#112233")
        XCTAssertEqual(rootGroup.children.count, 1)

        let layerGroup = try groupNode(from: rootGroup.children[0])
        XCTAssertEqual(layerGroup.id, "layer")
        XCTAssertEqual(layerGroup.classes, ["body-layer"])
        XCTAssertEqual(layerGroup.fill, "#112233")
        XCTAssertEqual(layerGroup.children.count, 2)

        let panelRect = try rectNode(from: layerGroup.children[0])
        XCTAssertEqual(panelRect.id, "panel")
        XCTAssertEqual(panelRect.x, 10)
        XCTAssertEqual(panelRect.y, 12)
        XCTAssertEqual(panelRect.width, 16)
        XCTAssertEqual(panelRect.height, 8)
        XCTAssertEqual(panelRect.fill, "#112233")

        let bodyUse = try useNode(from: layerGroup.children[1])
        XCTAssertEqual(bodyUse.id, "body-use")
        XCTAssertEqual(bodyUse.href, "#body")
        XCTAssertEqual(bodyUse.x, 2)
        XCTAssertEqual(bodyUse.y, 3)
        XCTAssertEqual(bodyUse.fill, "#112233")
    }

    func testParseParsesExtendedGeometryElements() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <circle id="dot" cx="8" cy="9" r="5" fill="none" stroke="#111111" stroke-width="1.5" opacity="0.6" />
              <ellipse id="shadow" cx="14" cy="15" rx="7" ry="3" fill="#222222" opacity="0.4" />
              <line id="divider" x1="1" y1="2" x2="30" y2="40" stroke="#333333" stroke-width="2" stroke-linecap="round" />
              <path id="curve" d="M 1 2 C 3 4, 5 6, 7 8" fill="none" stroke="#444444" stroke-width="0.5" stroke-linejoin="bevel" />
              <polygon id="shape" points="0,0 10,0 5,10" fill="#555555" opacity="0.8" />
              <polyline id="trail" points="0,0 2,3 4,5" fill="none" stroke="#666666" stroke-width="1.25" stroke-linecap="square" stroke-linejoin="round" />
            </svg>
            """
        )

        XCTAssertEqual(document.rootChildren.count, 6)

        let circle = try circleNode(from: document.rootChildren[0])
        XCTAssertEqual(circle.id, "dot")
        XCTAssertEqual(circle.cx, 8)
        XCTAssertEqual(circle.cy, 9)
        XCTAssertEqual(circle.r, 5)
        XCTAssertEqual(circle.fill, "none")
        XCTAssertEqual(circle.stroke, "#111111")
        XCTAssertEqual(circle.strokeWidth, 1.5)
        XCTAssertEqual(circle.opacity, 0.6)

        let ellipse = try ellipseNode(from: document.rootChildren[1])
        XCTAssertEqual(ellipse.id, "shadow")
        XCTAssertEqual(ellipse.cx, 14)
        XCTAssertEqual(ellipse.cy, 15)
        XCTAssertEqual(ellipse.rx, 7)
        XCTAssertEqual(ellipse.ry, 3)
        XCTAssertEqual(ellipse.fill, "#222222")
        XCTAssertEqual(ellipse.opacity, 0.4)

        let line = try lineNode(from: document.rootChildren[2])
        XCTAssertEqual(line.id, "divider")
        XCTAssertEqual(line.x1, 1)
        XCTAssertEqual(line.y1, 2)
        XCTAssertEqual(line.x2, 30)
        XCTAssertEqual(line.y2, 40)
        XCTAssertEqual(line.stroke, "#333333")
        XCTAssertEqual(line.strokeWidth, 2)
        XCTAssertEqual(line.strokeLinecap, "round")

        let path = try pathNode(from: document.rootChildren[3])
        XCTAssertEqual(path.id, "curve")
        XCTAssertEqual(path.d, "M 1 2 C 3 4, 5 6, 7 8")
        XCTAssertEqual(path.fill, "none")
        XCTAssertEqual(path.stroke, "#444444")
        XCTAssertEqual(path.strokeWidth, 0.5)
        XCTAssertEqual(path.strokeLinejoin, "bevel")

        let polygon = try polygonNode(from: document.rootChildren[4])
        XCTAssertEqual(polygon.id, "shape")
        XCTAssertEqual(polygon.points, "0,0 10,0 5,10")
        XCTAssertEqual(polygon.fill, "#555555")
        XCTAssertEqual(polygon.opacity, 0.8)

        let polyline = try polylineNode(from: document.rootChildren[5])
        XCTAssertEqual(polyline.id, "trail")
        XCTAssertEqual(polyline.points, "0,0 2,3 4,5")
        XCTAssertEqual(polyline.fill, "none")
        XCTAssertEqual(polyline.stroke, "#666666")
        XCTAssertEqual(polyline.strokeWidth, 1.25)
        XCTAssertEqual(polyline.strokeLinecap, "square")
        XCTAssertEqual(polyline.strokeLinejoin, "round")
    }

    func testParseParsesClipPathDefinitionsAndReferences() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <defs>
                <clipPath id="mask">
                  <rect id="mask-rect" x="1" y="2" width="18" height="12" />
                </clipPath>
              </defs>
              <g id="clipped-group" clip-path="url(#mask)">
                <rect id="subject" x="0" y="0" width="20" height="20" clip-path="url(#mask)" />
              </g>
            </svg>
            """
        )

        XCTAssertNotNil(document.defs["mask"])
        let clipPath = try clipPathNode(from: try XCTUnwrap(document.defs["mask"]))
        XCTAssertEqual(clipPath.id, "mask")
        XCTAssertEqual(clipPath.children.count, 1)

        let maskRect = try rectNode(from: clipPath.children[0])
        XCTAssertEqual(maskRect.id, "mask-rect")
        XCTAssertEqual(maskRect.x, 1)
        XCTAssertEqual(maskRect.y, 2)
        XCTAssertEqual(maskRect.width, 18)
        XCTAssertEqual(maskRect.height, 12)

        let group = try groupNode(from: try XCTUnwrap(document.rootChildren.first))
        XCTAssertEqual(group.id, "clipped-group")
        XCTAssertEqual(group.clipPathRef, "mask")
        XCTAssertEqual(group.children.count, 1)

        let subjectRect = try rectNode(from: group.children[0])
        XCTAssertEqual(subjectRect.id, "subject")
        XCTAssertEqual(subjectRect.clipPathRef, "mask")
    }

    func testParsePreservesGroupStrokeAttributesForInheritance() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <g id="outline" stroke="#000000" stroke-width="0.9" stroke-linecap="round" stroke-linejoin="bevel">
                <line id="divider" x1="1" y1="2" x2="30" y2="40" />
              </g>
            </svg>
            """
        )

        let group = try groupNode(from: try XCTUnwrap(document.rootChildren.first))
        XCTAssertEqual(group.stroke, "#000000")
        XCTAssertEqual(group.strokeWidth, 0.9)
        XCTAssertEqual(group.strokeLinecap, "round")
        XCTAssertEqual(group.strokeLinejoin, "bevel")
    }

    func testParseXMLCollectsStyleBlocksInsideAndOutsideDefs() {
        let xml = SVGParser.parseXML(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <defs>
                <style><![CDATA[
                  .inside { opacity: 0.5; }
                ]]></style>
              </defs>
              <style>
                .outside { opacity: 1; }
              </style>
            </svg>
            """
        )

        XCTAssertEqual(xml.styleBlocks.count, 2)
        XCTAssertTrue(xml.styleBlocks.contains { $0.contains(".inside { opacity: 0.5; }") })
        XCTAssertTrue(xml.styleBlocks.contains { $0.contains(".outside { opacity: 1; }") })
    }

    func testParseXMLReportsMalformedSVGAndDropsPartialTree() {
        let malformed = """
            <svg xmlns="http://www.w3.org/2000/svg">
              <g>
                <rect id="broken" x="1" y="1" width="2" height="2">
            </svg>
            """

        let xml = SVGParser.parseXML(malformed)
        XCTAssertNotNil(xml.parseErrorDescription)
        XCTAssertTrue(xml.defs.isEmpty)
        XCTAssertTrue(xml.rootChildren.isEmpty)
        XCTAssertTrue(xml.styleBlocks.isEmpty)

        let document = SVGParser.parse(malformed)
        XCTAssertTrue(document.defs.isEmpty)
        XCTAssertTrue(document.rootChildren.isEmpty)
        XCTAssertTrue(document.animations.isEmpty)
    }

    func testCSSParserParsesAnimationShorthandWithoutDelay() throws {
        let result = CSSParser.parse([
            ".breather { animation: breathe 3.2s ease-in-out infinite; }",
        ])

        XCTAssertEqual(result.animations.count, 0)
        XCTAssertEqual(result.animationBindings.count, 1)

        let binding = result.animationBindings[0]
        assertSelector(binding.selector, equalsClassName: "breather")
        XCTAssertEqual(binding.animationName, "breathe")
        XCTAssertEqual(binding.duration, 3.2, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .easeInOut)
        assertIterationCount(binding.iterationCount, equals: .infinite)
        assertAnimationDirection(binding.direction, equals: .normal)
        XCTAssertEqual(binding.delay, 0, accuracy: 0.0001)
        XCTAssertEqual(binding.fillMode, .none)
        XCTAssertNil(binding.transformOrigin)
        XCTAssertNil(binding.transformBox)
    }

    func testCSSParserParsesAnimationShorthandWithDelayAndFillMode() throws {
        let result = CSSParser.parse([
            ".fade { animation: fade-in 0.5s ease-out 1.2s 1 forwards; }",
        ])

        XCTAssertEqual(result.animationBindings.count, 1)

        let binding = result.animationBindings[0]
        assertSelector(binding.selector, equalsClassName: "fade")
        XCTAssertEqual(binding.animationName, "fade-in")
        XCTAssertEqual(binding.duration, 0.5, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .easeOut)
        assertIterationCount(binding.iterationCount, equals: .count(1))
        assertAnimationDirection(binding.direction, equals: .normal)
        XCTAssertEqual(binding.delay, 1.2, accuracy: 0.0001)
        XCTAssertEqual(binding.fillMode, .forwards)
    }

    func testCSSParserDefaultsMissingAnimationTimingFunctionToEase() throws {
        let result = CSSParser.parse([
            ".success { animation: jump 6s infinite; }",
        ])

        let binding = try XCTUnwrap(animationBinding(in: result.animationBindings, className: "success"))
        XCTAssertEqual(binding.animationName, "jump")
        XCTAssertEqual(binding.duration, 6, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .cubicBezier(0.25, 0.1, 0.25, 1))
        assertIterationCount(binding.iterationCount, equals: .infinite)
    }

    func testCSSParserParsesCommaSeparatedAnimationDeclarations() throws {
        let result = CSSParser.parse([
            ".multi { animation: fadeIn 1s linear, slideUp 0.5s ease-out; }",
        ])

        XCTAssertEqual(result.animationBindings.count, 2)

        let first = result.animationBindings[0]
        assertSelector(first.selector, equalsClassName: "multi")
        XCTAssertEqual(first.animationName, "fadeIn")
        XCTAssertEqual(first.duration, 1, accuracy: 0.0001)
        assertTimingFunction(first.timingFunction, equals: .linear)

        let second = result.animationBindings[1]
        assertSelector(second.selector, equalsClassName: "multi")
        XCTAssertEqual(second.animationName, "slideUp")
        XCTAssertEqual(second.duration, 0.5, accuracy: 0.0001)
        assertTimingFunction(second.timingFunction, equals: .easeOut)
    }

    func testCSSParserParsesAnimationLonghandProperties() {
        let result = CSSParser.parse([
            ".pulse { animation-name: pulse; animation-duration: 2s; animation-timing-function: linear; }",
        ])

        XCTAssertEqual(result.animationBindings.count, 1)

        let binding = result.animationBindings[0]
        assertSelector(binding.selector, equalsClassName: "pulse")
        XCTAssertEqual(binding.animationName, "pulse")
        XCTAssertEqual(binding.duration, 2, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .linear)
        assertIterationCount(binding.iterationCount, equals: .count(1))
        assertAnimationDirection(binding.direction, equals: .normal)
        XCTAssertEqual(binding.delay, 0, accuracy: 0.0001)
        XCTAssertEqual(binding.fillMode, .none)
    }

    func testCSSParserPreservesFractionalIterationCount() throws {
        let result = CSSParser.parse([
            ".pulse { animation-name: pulse; animation-duration: 2s; animation-iteration-count: 1.5; }",
        ])

        let binding = try XCTUnwrap(animationBinding(in: result.animationBindings, className: "pulse"))
        XCTAssertEqual(binding.animationName, "pulse")
        assertIterationCount(binding.iterationCount, equals: .count(1.5))
    }

    func testCSSParserParsesAnimationDirection() throws {
        let result = CSSParser.parse([
            ".wave { animation: wave 0.15s infinite alternate ease-in-out; }",
        ])

        let binding = try XCTUnwrap(animationBinding(in: result.animationBindings, className: "wave"))
        XCTAssertEqual(binding.animationName, "wave")
        assertAnimationDirection(binding.direction, equals: .alternate)
    }

    func testCSSParserParsesCubicBezierTimingFunction() {
        let result = CSSParser.parse([
            ".bounce { animation: bounce 0.4s cubic-bezier(0.25, 0.1, 0.25, 1) 1 forwards; }",
        ])

        XCTAssertEqual(result.animationBindings.count, 1)

        let binding = result.animationBindings[0]
        assertSelector(binding.selector, equalsClassName: "bounce")
        XCTAssertEqual(binding.animationName, "bounce")
        XCTAssertEqual(binding.duration, 0.4, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .cubicBezier(0.25, 0.1, 0.25, 1))
        assertIterationCount(binding.iterationCount, equals: .count(1))
        XCTAssertEqual(binding.fillMode, .forwards)
    }

    func testCSSParserParsesStepEndTimingFunction() throws {
        let result = CSSParser.parse([
            ".blink { animation: cursor-blink 0.62s step-end infinite; }",
        ])

        XCTAssertEqual(result.animationBindings.count, 1)

        let binding = try XCTUnwrap(animationBinding(in: result.animationBindings, className: "blink"))
        XCTAssertEqual(binding.animationName, "cursor-blink")
        XCTAssertEqual(binding.duration, 0.62, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .stepEnd)
        assertIterationCount(binding.iterationCount, equals: .infinite)
        assertAnimationDirection(binding.direction, equals: .normal)
    }

    func testCSSParserAnimationShorthandTreatsReservedKeywordsAsNonNames() throws {
        let result = CSSParser.parse([
            ".reserved { animation: ease 1s; }",
            ".named { animation: my-anim 1s ease; }",
        ])

        XCTAssertNil(animationBinding(in: result.animationBindings, className: "reserved"))

        let binding = try XCTUnwrap(animationBinding(in: result.animationBindings, className: "named"))
        XCTAssertEqual(binding.animationName, "my-anim")
        XCTAssertEqual(binding.duration, 1, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .cubicBezier(0.25, 0.1, 0.25, 1))
    }

    func testCSSParserParsesTransformOriginAndTransformBox() {
        let result = CSSParser.parse([
            ".pivot { animation: spin 1s linear infinite; transform-origin: 7.5px 10px; transform-box: fill-box; }",
        ])

        XCTAssertEqual(result.animationBindings.count, 1)

        let binding = result.animationBindings[0]
        assertSelector(binding.selector, equalsClassName: "pivot")
        XCTAssertEqual(binding.animationName, "spin")
        XCTAssertEqual(
            binding.transformOrigin,
            SVGTransformOrigin(
                x: .px(7.5),
                y: .px(10)
            )
        )
        XCTAssertEqual(binding.transformBox, "fill-box")
    }

    func testCSSParserParsesTransformOriginPercentAndKeywordUnits() throws {
        let result = CSSParser.parse([
            """
            .percent { animation: hop 1s linear infinite; transform-origin: 100% 50%; }
            .corner { animation: hop 1s linear infinite; transform-origin: top left; }
            .top-center { animation: hop 1s linear infinite; transform-origin: top center; }
            """,
        ])

        XCTAssertEqual(result.animationBindings.count, 3)

        let percent = try XCTUnwrap(animationBinding(in: result.animationBindings, className: "percent"))
        XCTAssertEqual(
            percent.transformOrigin,
            SVGTransformOrigin(
                x: .percent(100),
                y: .percent(50)
            )
        )

        let corner = try XCTUnwrap(animationBinding(in: result.animationBindings, className: "corner"))
        XCTAssertEqual(
            corner.transformOrigin,
            SVGTransformOrigin(
                x: .percent(0),
                y: .percent(0)
            )
        )

        let topCenter = try XCTUnwrap(animationBinding(in: result.animationBindings, className: "top-center"))
        XCTAssertEqual(
            topCenter.transformOrigin,
            SVGTransformOrigin(
                x: .percent(50),
                y: .percent(0)
            )
        )
    }

    func testCSSParserParsesStaticStyleBindings() throws {
        let result = CSSParser.parse([
            """
            .wave { fill: none; stroke: #0082FC; stroke-width: 0.6; opacity: 0; }
            .hidden { visibility: hidden; }
            .animated { animation: fade 1s linear infinite; transform-origin: 7.5px 10px; }
            """,
        ])

        XCTAssertEqual(result.staticStyleBindings.count, 3)

        let wave = try XCTUnwrap(staticStyleBinding(in: result.staticStyleBindings, className: "wave"))
        XCTAssertEqual(wave.properties["fill"], "none")
        XCTAssertEqual(wave.properties["stroke"], "#0082FC")
        XCTAssertEqual(wave.properties["stroke-width"], "0.6")
        XCTAssertEqual(wave.properties["opacity"], "0")
        XCTAssertNil(wave.properties["animation"])

        let hidden = try XCTUnwrap(staticStyleBinding(in: result.staticStyleBindings, className: "hidden"))
        XCTAssertEqual(hidden.properties["visibility"], "hidden")

        let animated = try XCTUnwrap(staticStyleBinding(in: result.staticStyleBindings, className: "animated"))
        XCTAssertEqual(animated.properties["transform-origin"], "7.5px 10px")
    }

    func testCSSParserParsesTransitionShorthand() {
        let result = CSSParser.parse([
            ".hover { transition: transform 0.2s ease-out 0.1s; }",
        ])

        XCTAssertEqual(result.transitions.count, 1)

        let transition = result.transitions[0]
        assertSelector(transition.selector, equalsClassName: "hover")
        XCTAssertEqual(transition.property, "transform")
        XCTAssertEqual(transition.duration, 0.2, accuracy: 0.0001)
        assertTimingFunction(transition.timingFunction, equals: .easeOut)
        XCTAssertEqual(transition.delay, 0.1, accuracy: 0.0001)
    }

    func testCSSParserDefaultsMissingTransitionTimingFunctionToEase() throws {
        let result = CSSParser.parse([
            ".hover { transition: opacity 0.2s; }",
        ])

        let transition = try XCTUnwrap(result.transitions.first)
        XCTAssertEqual(transition.property, "opacity")
        XCTAssertEqual(transition.duration, 0.2, accuracy: 0.0001)
        assertTimingFunction(transition.timingFunction, equals: .cubicBezier(0.25, 0.1, 0.25, 1))
        XCTAssertEqual(transition.delay, 0, accuracy: 0.0001)
    }

    func testCSSParserParsesKeyframesVariantsAndExtendedProperties() throws {
        let result = CSSParser.parse([
            """
            @keyframes breathe {
              0% { transform: scale(1); }
              50% { transform: scale(1.02); }
              100% { transform: scale(1); }
            }
            @keyframes fade {
              from { opacity: 0; }
              to { opacity: 1; }
            }
            @keyframes pulse {
              0%, 100% { opacity: 1; }
              50% { opacity: 0.5; }
            }
            @keyframes morph {
              0% { fill: #ffffff; visibility: hidden; stroke-width: 1; r: 3; width: 10; }
              100% { fill: #000000; visibility: visible; stroke-width: 2; r: 4; width: 12; }
            }
            """,
        ])

        XCTAssertEqual(result.animations.count, 4)

        let breathe = try XCTUnwrap(result.animations["breathe"])
        XCTAssertEqual(breathe.name, "breathe")
        XCTAssertEqual(breathe.keyframes.count, 3)
        XCTAssertEqual(breathe.keyframes[0].offsets, [0])
        XCTAssertEqual(breathe.keyframes[0].properties["transform"], "scale(1)")
        XCTAssertEqual(breathe.keyframes[1].offsets, [0.5])
        XCTAssertEqual(breathe.keyframes[1].properties["transform"], "scale(1.02)")
        XCTAssertEqual(breathe.keyframes[2].offsets, [1])
        XCTAssertEqual(breathe.keyframes[2].properties["transform"], "scale(1)")

        let fade = try XCTUnwrap(result.animations["fade"])
        XCTAssertEqual(fade.keyframes.count, 2)
        XCTAssertEqual(fade.keyframes[0].offsets, [0])
        XCTAssertEqual(fade.keyframes[0].properties["opacity"], "0")
        XCTAssertEqual(fade.keyframes[1].offsets, [1])
        XCTAssertEqual(fade.keyframes[1].properties["opacity"], "1")

        let pulse = try XCTUnwrap(result.animations["pulse"])
        XCTAssertEqual(pulse.keyframes.count, 2)
        XCTAssertEqual(pulse.keyframes[0].offsets, [0, 1])
        XCTAssertEqual(pulse.keyframes[0].properties["opacity"], "1")
        XCTAssertEqual(pulse.keyframes[1].offsets, [0.5])
        XCTAssertEqual(pulse.keyframes[1].properties["opacity"], "0.5")

        let morph = try XCTUnwrap(result.animations["morph"])
        XCTAssertEqual(morph.keyframes.count, 2)
        XCTAssertEqual(morph.keyframes[0].offsets, [0])
        XCTAssertEqual(morph.keyframes[0].properties["fill"], "#ffffff")
        XCTAssertEqual(morph.keyframes[0].properties["visibility"], "hidden")
        XCTAssertEqual(morph.keyframes[0].properties["stroke-width"], "1")
        XCTAssertEqual(morph.keyframes[0].properties["r"], "3")
        XCTAssertEqual(morph.keyframes[0].properties["width"], "10")
        XCTAssertEqual(morph.keyframes[1].offsets, [1])
        XCTAssertEqual(morph.keyframes[1].properties["fill"], "#000000")
        XCTAssertEqual(morph.keyframes[1].properties["visibility"], "visible")
        XCTAssertEqual(morph.keyframes[1].properties["stroke-width"], "2")
        XCTAssertEqual(morph.keyframes[1].properties["r"], "4")
        XCTAssertEqual(morph.keyframes[1].properties["width"], "12")
    }

    func testCSSParserParsesEmptyKeyframesBlock() throws {
        let result = CSSParser.parse([
            "@keyframes empty {}",
        ])

        let animation = try XCTUnwrap(result.animations["empty"])
        XCTAssertEqual(animation.name, "empty")
        XCTAssertTrue(animation.keyframes.isEmpty)
    }

    func testParseParsesInlineStyleAttributes() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <rect id="styled" x="1" y="2" width="3" height="4" style="animation-delay: 0.3s; opacity: 0" />
            </svg>
            """
        )

        let rect = try rectNode(from: try XCTUnwrap(document.rootChildren.first))
        XCTAssertEqual(rect.id, "styled")
        XCTAssertEqual(rect.inlineStyles["animation-delay"], "0.3s")
        XCTAssertEqual(rect.inlineStyles["opacity"], "0")
    }

    func testParseNormalizesInlineStyleDeclarationKeys() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <rect
                id="styled"
                x="1"
                y="2"
                width="3"
                height="4"
                style="ANIMATION-DELAY: 0.3s; TRANSITION: opacity 0.2s ease-out 0.1s; FILL: rgba(0,0,0,0.15);"
              />
            </svg>
            """
        )

        let rect = try rectNode(from: try XCTUnwrap(document.rootChildren.first))
        XCTAssertEqual(rect.inlineStyles["animation-delay"], "0.3s")
        XCTAssertEqual(rect.inlineStyles["transition"], "opacity 0.2s ease-out 0.1s")
        XCTAssertEqual(rect.inlineStyles["fill"], "rgba(0,0,0,0.15)")
    }

    func testParsePreservesRootShapeRenderingAndExtendedNodeAttributes() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg" shape-rendering="crispEdges">
              <defs>
                <rect id="tile" x="1" y="2" width="6" height="7" />
              </defs>
              <rect
                id="arm"
                x="0"
                y="9"
                width="2"
                height="2"
                fill="#DE886D"
                stroke="#546E7A"
                stroke-width="0.3"
                transform="rotate(-20, 2, 10)"
              />
              <use id="smoke" href="#tile" x="3" y="4" transform="translate(5, 4)" />
            </svg>
            """
        )

        XCTAssertEqual(document.shapeRendering, "crispEdges")

        let arm = try rectNode(from: document.rootChildren[0])
        XCTAssertEqual(arm.id, "arm")
        XCTAssertEqual(arm.transform, "rotate(-20, 2, 10)")
        XCTAssertEqual(arm.stroke, "#546E7A")
        XCTAssertEqual(arm.strokeWidth, 0.3)

        let smoke = try useNode(from: document.rootChildren[1])
        XCTAssertEqual(smoke.id, "smoke")
        XCTAssertEqual(smoke.transform, "translate(5, 4)")
    }

    func testParseAllowsValidAndMissingUseReferencesWithoutCrashing() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <defs>
                <rect id="existing" x="1" y="1" width="10" height="10" />
              </defs>
              <g id="uses">
                <use id="valid-use" href="#existing" />
                <use id="missing-use" href="#nonexistent" />
              </g>
            </svg>
            """
        )

        XCTAssertEqual(document.defs.count, 1)
        let group = try groupNode(from: try XCTUnwrap(document.rootChildren.first))
        XCTAssertEqual(group.id, "uses")
        XCTAssertEqual(group.children.count, 2)

        let validUse = try useNode(from: group.children[0])
        XCTAssertEqual(validUse.id, "valid-use")
        XCTAssertEqual(validUse.href, "#existing")

        let missingUse = try useNode(from: group.children[1])
        XCTAssertEqual(missingUse.id, "missing-use")
        XCTAssertEqual(missingUse.href, "#nonexistent")
    }

    func testParseSupportsUseXLinkHrefFallback() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
              <defs>
                <rect id="target" x="1" y="1" width="2" height="3" />
              </defs>
              <use id="legacy-use" xlink:href="#target" />
            </svg>
            """
        )

        let use = try useNode(from: try XCTUnwrap(document.rootChildren.first))
        XCTAssertEqual(use.id, "legacy-use")
        XCTAssertEqual(use.href, "#target")
    }

    func testParseRegistersDefsNestedInsideAnonymousWrapper() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <defs>
                <g>
                  <rect id="nested-tile" x="1" y="2" width="3" height="4" />
                </g>
              </defs>
              <use id="nested-use" href="#nested-tile" />
            </svg>
            """
        )

        let nestedTile = try rectNode(from: try XCTUnwrap(document.defs["nested-tile"]))
        XCTAssertEqual(nestedTile.id, "nested-tile")
        XCTAssertEqual(nestedTile.width, 3)
        XCTAssertEqual(nestedTile.height, 4)

        let nestedUse = try useNode(from: try XCTUnwrap(document.rootChildren.first))
        XCTAssertEqual(nestedUse.id, "nested-use")
        XCTAssertEqual(nestedUse.href, "#nested-tile")
    }

    func testParseRegistersDefsNestedInsideNamedWrapper() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <defs>
                <g id="sprite">
                  <rect id="nested-tile" x="1" y="2" width="3" height="4" />
                </g>
              </defs>
              <use id="nested-use" href="#nested-tile" />
            </svg>
            """
        )

        XCTAssertEqual(document.defsChildren.count, 1)

        let sprite = try groupNode(from: try XCTUnwrap(document.defs["sprite"]))
        XCTAssertEqual(sprite.id, "sprite")
        XCTAssertEqual(sprite.children.count, 1)

        let nestedTile = try rectNode(from: try XCTUnwrap(document.defs["nested-tile"]))
        XCTAssertEqual(nestedTile.width, 3)
        XCTAssertEqual(nestedTile.height, 4)

        let nestedUse = try useNode(from: try XCTUnwrap(document.rootChildren.first))
        let referenced = try rectNode(from: try XCTUnwrap(document.referencedNode(for: nestedUse)))
        XCTAssertEqual(referenced.id, "nested-tile")
    }

    func testParseAssemblesCompleteSVGDocument() throws {
        let document = SVGParser.parse(
            """
            <svg viewBox="0 0 24 24" width="24" height="24" xmlns="http://www.w3.org/2000/svg">
              <defs>
                <rect id="tile" x="1" y="2" width="6" height="7" />
                <style>
                .breather {
                  animation: breathe 3.2s ease-in-out infinite;
                  transform-origin: 7.5px 10px;
                  transform-box: fill-box;
                }
                .hover {
                    transition: transform 0.2s ease-out 0.1s;
                  }
                  @keyframes breathe {
                    0% { transform: scale(1); }
                    100% { transform: scale(1.02); }
                  }
                </style>
              </defs>
              <g id="scene" class="breather" fill="#abcdef">
                <use id="tile-use" href="#tile" x="3" y="4" />
                <rect id="hover-rect" class="hover" x="8" y="9" width="5" height="6" />
              </g>
            </svg>
            """
        )

        let viewBox = try XCTUnwrap(document.viewBox)
        XCTAssertEqual(viewBox.x, 0)
        XCTAssertEqual(viewBox.y, 0)
        XCTAssertEqual(viewBox.width, 24)
        XCTAssertEqual(viewBox.height, 24)
        XCTAssertEqual(document.width, 24)
        XCTAssertEqual(document.height, 24)
        XCTAssertEqual(document.defs.count, 1)
        XCTAssertEqual(document.rootChildren.count, 1)
        XCTAssertEqual(document.animations.count, 1)
        XCTAssertEqual(document.staticStyleBindings.count, 1)
        XCTAssertEqual(document.animationBindings.count, 1)
        XCTAssertEqual(document.animationStyleBindings.count, 1)
        XCTAssertEqual(document.transitions.count, 1)

        let tile = try rectNode(from: try XCTUnwrap(document.defs["tile"]))
        XCTAssertEqual(tile.id, "tile")
        XCTAssertEqual(tile.width, 6)
        XCTAssertEqual(tile.height, 7)

        let scene = try groupNode(from: document.rootChildren[0])
        XCTAssertEqual(scene.id, "scene")
        XCTAssertEqual(scene.classes, ["breather"])
        XCTAssertEqual(scene.fill, "#abcdef")
        XCTAssertEqual(scene.children.count, 2)

        let tileUse = try useNode(from: scene.children[0])
        XCTAssertEqual(tileUse.id, "tile-use")
        XCTAssertEqual(tileUse.href, "#tile")
        XCTAssertEqual(tileUse.x, 3)
        XCTAssertEqual(tileUse.y, 4)
        XCTAssertEqual(tileUse.fill, "#abcdef")

        let hoverRect = try rectNode(from: scene.children[1])
        XCTAssertEqual(hoverRect.id, "hover-rect")
        XCTAssertEqual(hoverRect.classes, ["hover"])
        XCTAssertEqual(hoverRect.fill, "#abcdef")
        XCTAssertEqual(hoverRect.x, 8)
        XCTAssertEqual(hoverRect.y, 9)
        XCTAssertEqual(hoverRect.width, 5)
        XCTAssertEqual(hoverRect.height, 6)

        let breathe = try XCTUnwrap(document.animations["breathe"])
        XCTAssertEqual(breathe.name, "breathe")
        XCTAssertEqual(breathe.keyframes.count, 2)
        XCTAssertEqual(breathe.keyframes[0].offsets, [0])
        XCTAssertEqual(breathe.keyframes[0].properties["transform"], "scale(1)")
        XCTAssertEqual(breathe.keyframes[1].offsets, [1])
        XCTAssertEqual(breathe.keyframes[1].properties["transform"], "scale(1.02)")

        let animationBinding = document.animationBindings[0]
        assertSelector(animationBinding.selector, equalsClassName: "breather")
        XCTAssertEqual(animationBinding.animationName, "breathe")
        XCTAssertEqual(animationBinding.duration, 3.2, accuracy: 0.0001)
        assertTimingFunction(animationBinding.timingFunction, equals: .easeInOut)
        assertIterationCount(animationBinding.iterationCount, equals: .infinite)
        XCTAssertEqual(animationBinding.delay, 0, accuracy: 0.0001)
        XCTAssertEqual(animationBinding.fillMode, .none)
        XCTAssertEqual(
            animationBinding.transformOrigin,
            SVGTransformOrigin(
                x: .px(7.5),
                y: .px(10)
            )
        )
        XCTAssertEqual(animationBinding.transformBox, "fill-box")

        let breatherStatic = try XCTUnwrap(staticStyleBinding(in: document.staticStyleBindings, className: "breather"))
        XCTAssertEqual(breatherStatic.properties["transform-origin"], "7.5px 10px")
        XCTAssertEqual(breatherStatic.properties["transform-box"], "fill-box")

        let transition = document.transitions[0]
        assertSelector(transition.selector, equalsClassName: "hover")
        XCTAssertEqual(transition.property, "transform")
        XCTAssertEqual(transition.duration, 0.2, accuracy: 0.0001)
        assertTimingFunction(transition.timingFunction, equals: .easeOut)
        XCTAssertEqual(transition.delay, 0.1, accuracy: 0.0001)
    }

    func testParseHandlesEmptySVGString() {
        let document = SVGParser.parse("")

        XCTAssertNil(document.viewBox)
        XCTAssertNil(document.width)
        XCTAssertNil(document.height)
        XCTAssertTrue(document.defs.isEmpty)
        XCTAssertTrue(document.rootChildren.isEmpty)
        XCTAssertTrue(document.animations.isEmpty)
        XCTAssertTrue(document.staticStyleBindings.isEmpty)
        XCTAssertTrue(document.animationBindings.isEmpty)
        XCTAssertTrue(document.animationStyleBindings.isEmpty)
        XCTAssertTrue(document.transitions.isEmpty)
    }

    func testParseHandlesSVGWithoutStyleBlocks() throws {
        let xml = SVGParser.parseXML(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <rect id="static" x="1" y="1" width="5" height="5" />
            </svg>
            """
        )
        XCTAssertTrue(xml.styleBlocks.isEmpty)

        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <rect id="static" x="1" y="1" width="5" height="5" />
            </svg>
            """
        )

        XCTAssertTrue(document.animations.isEmpty)
        XCTAssertTrue(document.animationBindings.isEmpty)
        XCTAssertTrue(document.animationStyleBindings.isEmpty)
        XCTAssertTrue(document.transitions.isEmpty)

        let rect = try rectNode(from: try XCTUnwrap(document.rootChildren.first))
        XCTAssertEqual(rect.id, "static")
        XCTAssertEqual(rect.x, 1)
        XCTAssertEqual(rect.y, 1)
        XCTAssertEqual(rect.width, 5)
        XCTAssertEqual(rect.height, 5)
    }

    func testCSSParserStripsCommentsBeforeParsingRules() throws {
        let result = CSSParser.parse([
            """
            /* ignore this block */
            .breather {
              /* inline comment */
              animation: breathe 1s linear infinite;
            }
            /* another comment */
            @keyframes breathe {
              from { opacity: 0; }
              to { opacity: 1; }
            }
            """,
        ])

        XCTAssertEqual(result.animationBindings.count, 1)
        XCTAssertEqual(result.animations.count, 1)

        let binding = result.animationBindings[0]
        assertSelector(binding.selector, equalsClassName: "breather")
        XCTAssertEqual(binding.animationName, "breathe")
        XCTAssertEqual(binding.duration, 1, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .linear)
        assertIterationCount(binding.iterationCount, equals: .infinite)

        let animation = try XCTUnwrap(result.animations["breathe"])
        XCTAssertEqual(animation.keyframes.count, 2)
        XCTAssertEqual(animation.keyframes[0].offsets, [0])
        XCTAssertEqual(animation.keyframes[0].properties["opacity"], "0")
        XCTAssertEqual(animation.keyframes[1].offsets, [1])
        XCTAssertEqual(animation.keyframes[1].properties["opacity"], "1")
    }

    func testAllSVGsParseWithoutCrash() throws {
        let svgDirectory = Self.projectRoot + "/Resources/svg"
        let filenames = try FileManager.default.contentsOfDirectory(atPath: svgDirectory)
            .filter { $0.hasPrefix("clawd-") && $0.hasSuffix(".svg") }
            .sorted()

        XCTAssertEqual(filenames.count, 51)

        for filename in filenames {
            let svg = try String(contentsOfFile: svgDirectory + "/\(filename)", encoding: .utf8)
            let document = SVGParser.parse(svg)
            let nodeCount = totalNodeCount(in: document)
            print("Parsed \(filename): \(nodeCount) nodes")

            XCTAssertTrue(
                document.viewBox != nil || !document.rootChildren.isEmpty,
                "Expected \(filename) to produce a viewBox or root children."
            )
        }
    }

    func testErrorSVGHasHcShakeWith28UniqueStops() throws {
        let document = SVGParser.parse(try loadSVG("clawd-error"))
        let shake = try XCTUnwrap(document.animations["hc-shake"])

        XCTAssertEqual(document.animations.count, 5)
        XCTAssertNotNil(document.animations["hc-arms-up"])
        XCTAssertNotNil(document.animations["hc-smoke-puff"])
        XCTAssertNotNil(document.animations["hc-alert-up"])
        XCTAssertNotNil(document.animations["hc-arms-up-r"])

        XCTAssertEqual(shake.keyframes.count, 6)

        let uniqueOffsets = Set(shake.keyframes.flatMap(\.offsets).map(normalizedOffset))
        XCTAssertEqual(uniqueOffsets.count, 28)

        XCTAssertTrue(containsNodeType(.group, in: document.rootChildren))
        XCTAssertTrue(containsNodeType(.rect, in: document.rootChildren))
        XCTAssertTrue(containsNodeType(.line, in: document.rootChildren))
    }

    func testCollapseSleepSVGHas14Keyframes() throws {
        let document = SVGParser.parse(try loadSVG("clawd-collapse-sleep"))

        XCTAssertEqual(document.animations.count, 14)
        XCTAssertTrue(document.animationBindings.contains { $0.fillMode == .forwards })
        XCTAssertTrue(document.animationBindings.contains { $0.delay > 0 })
    }

    func testIdleLivingSVGHas15PlusStopKeyframes() throws {
        let document = SVGParser.parse(try loadSVG("clawd-idle-living"))
        let maxKeyframeCount = document.animations.values.map(\.keyframes.count).max() ?? 0

        XCTAssertGreaterThanOrEqual(
            maxKeyframeCount,
            14,
            "Current clawd-idle-living.svg tops out at \(maxKeyframeCount) keyframe blocks."
        )
    }

    func testWorkingBeaconSVGHasExtendedKeyframeProperties() throws {
        let document = SVGParser.parse(try loadSVG("clawd-working-beacon"))
        let waveExpand = try XCTUnwrap(document.animations["wave-expand"])
        let waveProperties = Set(waveExpand.keyframes.flatMap { $0.properties.keys })

        XCTAssertTrue(waveProperties.contains("r"))
        XCTAssertTrue(waveProperties.contains("stroke-width"))
        XCTAssertTrue(waveProperties.contains("opacity"))

        let antBlink = try XCTUnwrap(document.animations["ant-blink"])
        let antBlinkProperties = Set(antBlink.keyframes.flatMap { $0.properties.keys })
        XCTAssertTrue(antBlinkProperties.contains("fill"))

        let waveRule = try XCTUnwrap(staticStyleBinding(in: document.staticStyleBindings, className: "wave"))
        XCTAssertEqual(waveRule.properties["fill"], "none")
        XCTAssertEqual(waveRule.properties["stroke-width"], "0.6")
        XCTAssertEqual(waveRule.properties["opacity"], "0")
    }

    func testWakeSVGPreservesSharedAnimationLonghandsAndStandaloneTransformOriginRules() throws {
        let document = SVGParser.parse(try loadSVG("clawd-wake"))

        let onceStyle = try XCTUnwrap(animationStyleBinding(in: document.animationStyleBindings, className: "once"))
        XCTAssertNil(onceStyle.animationName)
        XCTAssertEqual(try XCTUnwrap(onceStyle.duration), 3.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(onceStyle.fillMode), .forwards)
        assertIterationCount(try XCTUnwrap(onceStyle.iterationCount), equals: .count(1))

        let scaleTopLeftStyle = try XCTUnwrap(animationStyleBinding(in: document.animationStyleBindings, className: "scale-top-left"))
        XCTAssertNil(scaleTopLeftStyle.animationName)
        XCTAssertEqual(scaleTopLeftStyle.transformBox, "fill-box")
        XCTAssertEqual(
            scaleTopLeftStyle.transformOrigin,
            SVGTransformOrigin(
                x: .percent(0),
                y: .percent(0)
            )
        )

        let scaleTopLeftStatic = try XCTUnwrap(staticStyleBinding(in: document.staticStyleBindings, className: "scale-top-left"))
        XCTAssertEqual(scaleTopLeftStatic.properties["transform-box"], "fill-box")
        XCTAssertEqual(scaleTopLeftStatic.properties["transform-origin"], "top left")
    }

    func testIdleFollowSVGPreservesStandaloneShadowTransformOriginRule() throws {
        let document = SVGParser.parse(try loadSVG("clawd-idle-follow"))

        let shadowRule = try XCTUnwrap(staticStyleBinding(in: document.staticStyleBindings, id: "shadow-js"))
        XCTAssertEqual(shadowRule.properties["transform-origin"], "7.5px 15px")
    }

    func testPercentagePrecision() throws {
        let document = SVGParser.parse(try loadSVG("clawd-idle-living"))
        let offsets = document.animations.values.flatMap(\.keyframes).flatMap(\.offsets)

        XCTAssertFalse(offsets.isEmpty)

        for offset in offsets {
            XCTAssertFalse(offset.isNaN)
            XCTAssertGreaterThanOrEqual(offset, 0)
        }

        if let offset1428 = offsets.first(where: { abs($0 - 0.1428) < 0.001 }) {
            XCTAssertEqual(offset1428, 0.1428, accuracy: 0.0001)
        }
    }

    func testGoingAwaySVGHasClipPathAndMultipleUseRefs() throws {
        let document = SVGParser.parse(try loadSVG("clawd-going-away"))

        XCTAssertTrue(document.defs.values.contains { node in
            if case .clipPath = node {
                return true
            }
            return false
        })
        XCTAssertGreaterThanOrEqual(countNodes(of: .use, in: document.rootChildren), 8)
    }

    func testReactDoubleJumpSVGPreservesPercentTransformOrigin() throws {
        let document = SVGParser.parse(try loadSVG("clawd-react-double-jump"))
        let leftArm = try XCTUnwrap(animationBinding(in: document.animationBindings, className: "hc-dj-larm"))

        XCTAssertEqual(
            leftArm.transformOrigin,
            SVGTransformOrigin(
                x: .percent(100),
                y: .percent(50)
            )
        )
        XCTAssertEqual(leftArm.transformBox, "fill-box")
    }

    func testRealSVGsPreserveRectAndUseTransforms() throws {
        let pushing = SVGParser.parse(try loadSVG("clawd-working-pushing"))
        let rectTransforms = collectRects(in: pushing.rootChildren).compactMap(\.transform)
        XCTAssertTrue(rectTransforms.contains("rotate(-20, 2, 10)"))
        XCTAssertTrue(rectTransforms.contains("rotate(-25, 13, 10)"))

        let overheated = SVGParser.parse(try loadSVG("clawd-working-overheated"))
        let useTransforms = collectUses(in: overheated.rootChildren).compactMap(\.transform)
        XCTAssertTrue(useTransforms.contains("translate(5, 4)"))
        XCTAssertTrue(useTransforms.contains("translate(8, 3)"))
        XCTAssertTrue(useTransforms.contains("translate(11, 4)"))
    }

    func testParseResolvesInlineAnimationBindingsFromStyleAttributes() throws {
        let document = SVGParser.parse(try loadSVG("clawd-error"))

        let inlineArm = try XCTUnwrap(
            document.inlineAnimationBindings.first { binding in
                binding.animationName == "hc-arms-up-r"
            }
        )
        XCTAssertEqual(
            inlineArm.transformOrigin,
            SVGTransformOrigin(
                x: .px(13),
                y: .px(10)
            )
        )
        XCTAssertEqual(inlineArm.nodePath, "root/0/7")
        XCTAssertNil(inlineArm.nodeID)
        XCTAssertEqual(inlineArm.classes, [])

        let smokeBindings = document.inlineAnimationBindings
            .filter { $0.animationName == "hc-smoke-puff" }
            .sorted { $0.delay < $1.delay }

        XCTAssertEqual(smokeBindings.count, 2)
        XCTAssertEqual(smokeBindings[0].delay, 0.2, accuracy: 0.0001)
        XCTAssertEqual(smokeBindings[1].delay, 0.4, accuracy: 0.0001)
    }

    func testParseResolvesInlineAnimationDelayOverridesForClassAnimations() throws {
        let document = SVGParser.parse(try loadSVG("clawd-notification"))
        let rippleBindings = document.inlineAnimationBindings
            .filter { $0.animationName == "hc-ripple-out" }
            .sorted { $0.delay < $1.delay }

        XCTAssertEqual(rippleBindings.count, 2)
        XCTAssertEqual(rippleBindings[0].delay, 0, accuracy: 0.0001)
        XCTAssertEqual(rippleBindings[1].delay, 0.2, accuracy: 0.0001)
        XCTAssertEqual(rippleBindings[0].nodePath, "root/2")
        XCTAssertEqual(rippleBindings[0].classes, ["hc-ripple"])
    }

    func testParseResolvesInlineAnimationOverridesAcrossUtilityLonghands() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <style>
                .once {
                  animation-duration: 3.5s;
                  animation-iteration-count: 1;
                  animation-fill-mode: forwards;
                }
                .shadow-wake {
                  animation-name: shadow-wake;
                  transform-origin: 7.5px 15px;
                }
                @keyframes shadow-wake {
                  from { opacity: 0; }
                  to { opacity: 1; }
                }
              </style>
              <rect
                id="shadow"
                class="once shadow-wake"
                x="0"
                y="0"
                width="1"
                height="1"
                style="animation-delay: 0.2s;"
              />
            </svg>
            """
        )

        XCTAssertEqual(document.inlineAnimationBindings.count, 1)

        let inlineBinding = try XCTUnwrap(document.inlineAnimationBindings.first)
        XCTAssertEqual(inlineBinding.animationName, "shadow-wake")
        XCTAssertEqual(inlineBinding.duration, 3.5, accuracy: 0.0001)
        XCTAssertEqual(inlineBinding.delay, 0.2, accuracy: 0.0001)
        XCTAssertEqual(inlineBinding.fillMode, .forwards)
        assertIterationCount(inlineBinding.iterationCount, equals: .count(1))
        XCTAssertEqual(
            inlineBinding.transformOrigin,
            SVGTransformOrigin(
                x: .px(7.5),
                y: .px(15)
            )
        )
    }

    func testParseFansOutSharedTransformContextAcrossMultipleAnimations() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <style>
                .multi {
                  animation: fadeIn 1s linear, slideUp 0.5s ease-out;
                }
                .pivot {
                  transform-origin: 10px 20px;
                  transform-box: fill-box;
                }
                @keyframes fadeIn {
                  from { opacity: 0; }
                  to { opacity: 1; }
                }
                @keyframes slideUp {
                  from { transform: translateY(2px); }
                  to { transform: translateY(0); }
                }
              </style>
              <rect
                id="subject"
                class="multi pivot"
                x="0"
                y="0"
                width="1"
                height="1"
                style="animation-delay: 0.2s;"
              />
            </svg>
            """
        )

        let bindings = document.inlineAnimationBindings.sorted { $0.animationName < $1.animationName }
        XCTAssertEqual(bindings.count, 2)

        XCTAssertEqual(bindings[0].animationName, "fadeIn")
        XCTAssertEqual(bindings[0].delay, 0.2, accuracy: 0.0001)
        XCTAssertEqual(
            bindings[0].transformOrigin,
            SVGTransformOrigin(
                x: .px(10),
                y: .px(20)
            )
        )
        XCTAssertEqual(bindings[0].transformBox, "fill-box")

        XCTAssertEqual(bindings[1].animationName, "slideUp")
        XCTAssertEqual(bindings[1].delay, 0.2, accuracy: 0.0001)
        XCTAssertEqual(
            bindings[1].transformOrigin,
            SVGTransformOrigin(
                x: .px(10),
                y: .px(20)
            )
        )
        XCTAssertEqual(bindings[1].transformBox, "fill-box")
    }

    func testParseInlineAnimationNameMergesInheritedUtilityDefaults() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <style>
                .once {
                  animation-duration: 3.5s;
                  animation-iteration-count: 1;
                  animation-fill-mode: forwards;
                }
                @keyframes foo {
                  from { opacity: 0; }
                  to { opacity: 1; }
                }
              </style>
              <rect
                id="shadow"
                class="once"
                x="0"
                y="0"
                width="1"
                height="1"
                style="animation-name: foo;"
              />
            </svg>
            """
        )

        let binding = try XCTUnwrap(document.inlineAnimationBindings.first)
        XCTAssertEqual(binding.animationName, "foo")
        XCTAssertEqual(binding.duration, 3.5, accuracy: 0.0001)
        assertIterationCount(binding.iterationCount, equals: .count(1))
        XCTAssertEqual(binding.fillMode, .forwards)
    }

    func testParseInlineAnimationUsesHigherSpecificityLonghandOverrides() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <style>
                .pulse {
                  animation-name: pulse;
                  animation-duration: 1s;
                  animation-timing-function: linear;
                }
                #subject {
                  animation-duration: 2s;
                }
                @keyframes pulse {
                  from { opacity: 0; }
                  to { opacity: 1; }
                }
              </style>
              <rect
                id="subject"
                class="pulse"
                x="0"
                y="0"
                width="1"
                height="1"
                style="animation-delay: 0.2s;"
              />
            </svg>
            """
        )

        let binding = try XCTUnwrap(document.inlineAnimationBindings.first)
        XCTAssertEqual(binding.animationName, "pulse")
        XCTAssertEqual(binding.duration, 2, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .linear)
        XCTAssertEqual(binding.delay, 0.2, accuracy: 0.0001)
    }

    func testParseResolvesInlineTransitionOverridesFromStyleAttributes() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <style>
                .hover {
                  transition: transform 0.2s ease-out 0.1s;
                }
              </style>
              <rect
                id="hover-target"
                class="hover"
                x="0"
                y="0"
                width="1"
                height="1"
                style="transition-duration: 0.5s;"
              />
            </svg>
            """
        )

        let binding = try XCTUnwrap(document.inlineTransitionBindings.first)
        XCTAssertEqual(binding.property, "transform")
        XCTAssertEqual(binding.duration, 0.5, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .easeOut)
        XCTAssertEqual(binding.delay, 0.1, accuracy: 0.0001)
        XCTAssertEqual(binding.nodeID, "hover-target")
    }

    func testParseInlineTransitionPropertyInheritsHigherSpecificityDefaults() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg">
              <style>
                .hover {
                  transition: transform 0.2s linear;
                }
                #subject {
                  transition: transform 0.5s ease-out 0.1s;
                }
              </style>
              <rect
                id="subject"
                class="hover"
                x="0"
                y="0"
                width="1"
                height="1"
                style="transition-property: opacity;"
              />
            </svg>
            """
        )

        let binding = try XCTUnwrap(document.inlineTransitionBindings.first)
        XCTAssertEqual(binding.property, "opacity")
        XCTAssertEqual(binding.duration, 0.5, accuracy: 0.0001)
        assertTimingFunction(binding.timingFunction, equals: .easeOut)
        XCTAssertEqual(binding.delay, 0.1, accuracy: 0.0001)
    }

    func testParseSupportsNumericAttributesWithPxAndPercentUnits() throws {
        let document = SVGParser.parse(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="120px" height="80%">
              <defs>
                <rect id="tile" x="1" y="2" width="3" height="4" />
              </defs>
              <rect id="subject" x=".5px" y="25%" width="3px" height="4%" rx="1.25px" ry=".75" />
              <circle id="dot" cx=".25px" cy="50%" r="2px" />
              <use id="clone" href="#tile" x="5px" y="10%" />
            </svg>
            """
        )

        XCTAssertEqual(document.width, 120)
        XCTAssertEqual(document.height, 80)

        let rect = try rectNode(from: document.rootChildren[0])
        XCTAssertEqual(rect.x, 0.5)
        XCTAssertEqual(rect.y, 25)
        XCTAssertEqual(rect.width, 3)
        XCTAssertEqual(rect.height, 4)
        XCTAssertEqual(rect.rx, 1.25)
        XCTAssertEqual(rect.ry, 0.75)

        let circle = try circleNode(from: document.rootChildren[1])
        XCTAssertEqual(circle.cx, 0.25)
        XCTAssertEqual(circle.cy, 50)
        XCTAssertEqual(circle.r, 2)

        let use = try useNode(from: document.rootChildren[2])
        XCTAssertEqual(use.x, 5)
        XCTAssertEqual(use.y, 10)
    }

    func testWorkingPushingSVGPreservesAlternateAnimationDirection() throws {
        let document = SVGParser.parse(try loadSVG("clawd-working-pushing"))

        let actionBody = try XCTUnwrap(animationBinding(in: document.animationBindings, className: "action-body"))
        assertAnimationDirection(actionBody.direction, equals: .alternate)

        let blockShake = try XCTUnwrap(animationBinding(in: document.animationBindings, className: "block-shake"))
        assertAnimationDirection(blockShake.direction, equals: .alternate)
    }
}

private enum SVGNodeTypeError: Error {
    case mismatch
}

private enum ExpectedTimingFunction {
    case easeInOut
    case linear
    case easeOut
    case easeIn
    case stepEnd
    case cubicBezier(CGFloat, CGFloat, CGFloat, CGFloat)
}

private enum ExpectedIterationCount {
    case infinite
    case count(Double)
}

private enum ExpectedAnimationDirection {
    case normal
    case reverse
    case alternate
    case alternateReverse
}

private func assertSelector(
    _ actual: CSSSelector,
    equalsClassName expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .className(let name) = actual else {
        XCTFail("Expected class selector '\(expected)'.", file: file, line: line)
        return
    }
    XCTAssertEqual(name, expected, file: file, line: line)
}

private func assertTimingFunction(
    _ actual: TimingFunction,
    equals expected: ExpectedTimingFunction,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch (actual, expected) {
    case (.easeInOut, .easeInOut),
         (.linear, .linear),
         (.easeOut, .easeOut),
         (.easeIn, .easeIn),
         (.stepEnd, .stepEnd):
        return
    case let (.cubicBezier(a1, b1, c1, d1), .cubicBezier(a2, b2, c2, d2)):
        XCTAssertEqual(a1, a2, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(b1, b2, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(c1, c2, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(d1, d2, accuracy: 0.0001, file: file, line: line)
    default:
        XCTFail("Unexpected timing function.", file: file, line: line)
    }
}

private func assertIterationCount(
    _ actual: AnimationIterationCount,
    equals expected: ExpectedIterationCount,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch (actual, expected) {
    case (.infinite, .infinite):
        return
    case let (.count(actualValue), .count(expectedValue)):
        XCTAssertEqual(actualValue, expectedValue, accuracy: 0.0001, file: file, line: line)
    default:
        XCTFail("Unexpected iteration count.", file: file, line: line)
    }
}

private func assertAnimationDirection(
    _ actual: AnimationDirection,
    equals expected: ExpectedAnimationDirection,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch (actual, expected) {
    case (.normal, .normal),
         (.reverse, .reverse),
         (.alternate, .alternate),
         (.alternateReverse, .alternateReverse):
        return
    default:
        XCTFail("Unexpected animation direction.", file: file, line: line)
    }
}

private func animationBinding(
    in bindings: [SVGAnimationBinding],
    className: String
) -> SVGAnimationBinding? {
    bindings.first { binding in
        guard case .className(let name) = binding.selector else {
            return false
        }
        return name == className
    }
}

private func staticStyleBinding(
    in bindings: [SVGStaticStyleBinding],
    className: String
) -> SVGStaticStyleBinding? {
    bindings.first { binding in
        guard case .className(let name) = binding.selector else {
            return false
        }
        return name == className
    }
}

private func staticStyleBinding(
    in bindings: [SVGStaticStyleBinding],
    id: String
) -> SVGStaticStyleBinding? {
    bindings.first { binding in
        guard case .id(let name) = binding.selector else {
            return false
        }
        return name == id
    }
}

private func animationStyleBinding(
    in bindings: [SVGAnimationStyleBinding],
    className: String
) -> SVGAnimationStyleBinding? {
    bindings.first { binding in
        guard case .className(let name) = binding.selector else {
            return false
        }
        return name == className
    }
}

private func groupNode(from node: SVGNode, file: StaticString = #filePath, line: UInt = #line) throws -> SVGGroup {
    guard case .group(let group) = node else {
        XCTFail("Expected group node.", file: file, line: line)
        throw SVGNodeTypeError.mismatch
    }
    return group
}

private func rectNode(from node: SVGNode, file: StaticString = #filePath, line: UInt = #line) throws -> SVGRect {
    guard case .rect(let rect) = node else {
        XCTFail("Expected rect node.", file: file, line: line)
        throw SVGNodeTypeError.mismatch
    }
    return rect
}

private func useNode(from node: SVGNode, file: StaticString = #filePath, line: UInt = #line) throws -> SVGUse {
    guard case .use(let use) = node else {
        XCTFail("Expected use node.", file: file, line: line)
        throw SVGNodeTypeError.mismatch
    }
    return use
}

private func circleNode(from node: SVGNode, file: StaticString = #filePath, line: UInt = #line) throws -> SVGCircle {
    guard case .circle(let circle) = node else {
        XCTFail("Expected circle node.", file: file, line: line)
        throw SVGNodeTypeError.mismatch
    }
    return circle
}

private func ellipseNode(from node: SVGNode, file: StaticString = #filePath, line: UInt = #line) throws -> SVGEllipse {
    guard case .ellipse(let ellipse) = node else {
        XCTFail("Expected ellipse node.", file: file, line: line)
        throw SVGNodeTypeError.mismatch
    }
    return ellipse
}

private func lineNode(from node: SVGNode, file: StaticString = #filePath, line: UInt = #line) throws -> SVGLine {
    guard case .line(let lineNode) = node else {
        XCTFail("Expected line node.", file: file, line: line)
        throw SVGNodeTypeError.mismatch
    }
    return lineNode
}

private func pathNode(from node: SVGNode, file: StaticString = #filePath, line: UInt = #line) throws -> SVGPath {
    guard case .path(let path) = node else {
        XCTFail("Expected path node.", file: file, line: line)
        throw SVGNodeTypeError.mismatch
    }
    return path
}

private func polygonNode(from node: SVGNode, file: StaticString = #filePath, line: UInt = #line) throws -> SVGPolygon {
    guard case .polygon(let polygon) = node else {
        XCTFail("Expected polygon node.", file: file, line: line)
        throw SVGNodeTypeError.mismatch
    }
    return polygon
}

private func polylineNode(from node: SVGNode, file: StaticString = #filePath, line: UInt = #line) throws -> SVGPolyline {
    guard case .polyline(let polyline) = node else {
        XCTFail("Expected polyline node.", file: file, line: line)
        throw SVGNodeTypeError.mismatch
    }
    return polyline
}

private func clipPathNode(from node: SVGNode, file: StaticString = #filePath, line: UInt = #line) throws -> SVGClipPathDef {
    guard case .clipPath(let clipPath) = node else {
        XCTFail("Expected clipPath node.", file: file, line: line)
        throw SVGNodeTypeError.mismatch
    }
    return clipPath
}

private enum SVGNodeKind {
    case group
    case rect
    case use
    case circle
    case ellipse
    case line
    case path
    case polygon
    case polyline
    case clipPath
}

private func totalNodeCount(in document: SVGDocument) -> Int {
    totalNodeCount(in: document.rootChildren) + totalNodeCount(in: document.defsChildren)
}

private func totalNodeCount(in nodes: [SVGNode]) -> Int {
    nodes.reduce(0) { $0 + totalNodeCount(in: $1) }
}

private func totalNodeCount(in node: SVGNode) -> Int {
    1 + childNodes(of: node).reduce(0) { $0 + totalNodeCount(in: $1) }
}

private func containsNodeType(_ kind: SVGNodeKind, in nodes: [SVGNode]) -> Bool {
    countNodes(of: kind, in: nodes) > 0
}

private func countNodes(of kind: SVGNodeKind, in nodes: [SVGNode]) -> Int {
    nodes.reduce(0) { $0 + countNodes(of: kind, in: $1) }
}

private func countNodes(of kind: SVGNodeKind, in node: SVGNode) -> Int {
    let current = matches(kind, node: node) ? 1 : 0
    return current + childNodes(of: node).reduce(0) { $0 + countNodes(of: kind, in: $1) }
}

private func childNodes(of node: SVGNode) -> [SVGNode] {
    switch node {
    case .group(let group):
        return group.children
    case .clipPath(let clipPath):
        return clipPath.children
    case .rect, .use, .circle, .ellipse, .line, .path, .polygon, .polyline:
        return []
    }
}

private func collectRects(in nodes: [SVGNode]) -> [SVGRect] {
    nodes.flatMap(collectRects(in:))
}

private func collectRects(in node: SVGNode) -> [SVGRect] {
    switch node {
    case .rect(let rect):
        return [rect]
    case .group(let group):
        return collectRects(in: group.children)
    case .clipPath(let clipPath):
        return collectRects(in: clipPath.children)
    case .use, .circle, .ellipse, .line, .path, .polygon, .polyline:
        return []
    }
}

private func collectUses(in nodes: [SVGNode]) -> [SVGUse] {
    nodes.flatMap(collectUses(in:))
}

private func collectUses(in node: SVGNode) -> [SVGUse] {
    switch node {
    case .use(let use):
        return [use]
    case .group(let group):
        return collectUses(in: group.children)
    case .clipPath(let clipPath):
        return collectUses(in: clipPath.children)
    case .rect, .circle, .ellipse, .line, .path, .polygon, .polyline:
        return []
    }
}

private func matches(_ kind: SVGNodeKind, node: SVGNode) -> Bool {
    switch (kind, node) {
    case (.group, .group),
         (.rect, .rect),
         (.use, .use),
         (.circle, .circle),
         (.ellipse, .ellipse),
         (.line, .line),
         (.path, .path),
         (.polygon, .polygon),
         (.polyline, .polyline),
         (.clipPath, .clipPath):
        return true
    default:
        return false
    }
}

private func normalizedOffset(_ offset: CGFloat) -> Int {
    Int((offset * 10_000).rounded())
}
