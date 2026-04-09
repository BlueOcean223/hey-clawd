import CoreGraphics
import XCTest
@testable import HeyClawdApp

final class SVGParserTests: XCTestCase {
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

        XCTAssertEqual(document.defs.count, 1)
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
        XCTAssertEqual(binding.delay, 1.2, accuracy: 0.0001)
        XCTAssertEqual(binding.fillMode, .forwards)
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
        XCTAssertEqual(binding.delay, 0, accuracy: 0.0001)
        XCTAssertEqual(binding.fillMode, .none)
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

    func testCSSParserParsesTransformOriginAndTransformBox() {
        let result = CSSParser.parse([
            ".pivot { animation: spin 1s linear infinite; transform-origin: 7.5px 10px; transform-box: fill-box; }",
        ])

        XCTAssertEqual(result.animationBindings.count, 1)

        let binding = result.animationBindings[0]
        assertSelector(binding.selector, equalsClassName: "pivot")
        XCTAssertEqual(binding.animationName, "spin")
        XCTAssertEqual(binding.transformOrigin, CGPoint(x: 7.5, y: 10))
        XCTAssertEqual(binding.transformBox, "fill-box")
    }

    func testCSSParserParsesTransitionShorthand() {
        let result = CSSParser.parse([
            ".hover { transition: transform 0.2s ease-out; }",
        ])

        XCTAssertEqual(result.transitions.count, 1)

        let transition = result.transitions[0]
        assertSelector(transition.selector, equalsClassName: "hover")
        XCTAssertEqual(transition.property, "transform")
        XCTAssertEqual(transition.duration, 0.2, accuracy: 0.0001)
        assertTimingFunction(transition.timingFunction, equals: .easeOut)
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
                    transition: transform 0.2s ease-out;
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
        XCTAssertEqual(document.animationBindings.count, 1)
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
        XCTAssertEqual(animationBinding.transformOrigin, CGPoint(x: 7.5, y: 10))
        XCTAssertEqual(animationBinding.transformBox, "fill-box")

        let transition = document.transitions[0]
        assertSelector(transition.selector, equalsClassName: "hover")
        XCTAssertEqual(transition.property, "transform")
        XCTAssertEqual(transition.duration, 0.2, accuracy: 0.0001)
        assertTimingFunction(transition.timingFunction, equals: .easeOut)
    }

    func testParseHandlesEmptySVGString() {
        let document = SVGParser.parse("")

        XCTAssertNil(document.viewBox)
        XCTAssertNil(document.width)
        XCTAssertNil(document.height)
        XCTAssertTrue(document.defs.isEmpty)
        XCTAssertTrue(document.rootChildren.isEmpty)
        XCTAssertTrue(document.animations.isEmpty)
        XCTAssertTrue(document.animationBindings.isEmpty)
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
}

private enum SVGNodeTypeError: Error {
    case mismatch
}

private enum ExpectedTimingFunction {
    case easeInOut
    case linear
    case easeOut
    case easeIn
    case cubicBezier(CGFloat, CGFloat, CGFloat, CGFloat)
}

private enum ExpectedIterationCount {
    case infinite
    case count(Int)
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
         (.easeIn, .easeIn):
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
        XCTAssertEqual(actualValue, expectedValue, file: file, line: line)
    default:
        XCTFail("Unexpected iteration count.", file: file, line: line)
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
