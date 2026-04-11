import Foundation
import CoreGraphics
import QuartzCore
import XCTest
@testable import HeyClawdApp

@MainActor
final class PetViewPipelineTests: XCTestCase {
    private static var projectRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    private static var svgDirectoryURL: URL {
        URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("svg", isDirectory: true)
    }

    private struct SVGFixture {
        let filename: String
        let markup: String
    }

    func testAllSVGsParseSuccessfully() throws {
        let fixtures = try loadAllSVGFixtures()
        var failures: [String] = []

        for fixture in fixtures {
            let document = SVGParser.parse(fixture.markup)

            if document.rootChildren.isEmpty {
                failures.append("\(fixture.filename): parse produced empty rootChildren")
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testAllSVGsBuildLayerTree() throws {
        let fixtures = try loadAllSVGFixtures()
        var failures: [String] = []

        for fixture in fixtures {
            let document = SVGParser.parse(fixture.markup)
            let rootLayer = CALayerRenderer.build(document)

            if rootLayer.bounds.width <= 0 || rootLayer.bounds.height <= 0 {
                failures.append("\(fixture.filename): build produced zero-sized root bounds \(rootLayer.bounds)")
            }

            if rootLayer.sublayers?.isEmpty ?? true {
                failures.append("\(fixture.filename): build produced no sublayers")
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testAllSVGsApplyAnimations() throws {
        let fixtures = try loadAllSVGFixtures()
        var failures: [String] = []
        var animatedSVGCount = 0

        for fixture in fixtures {
            let document = SVGParser.parse(fixture.markup)
            let rootLayer = CALayerRenderer.build(document)

            CAAnimationBuilder.apply(document, to: rootLayer)

            if totalAnimationCount(in: rootLayer) > 0 {
                animatedSVGCount += 1
            }

            if rootLayer.sublayers?.isEmpty ?? true {
                failures.append("\(fixture.filename): apply left root layer without sublayers")
            }
        }

        print("PetViewPipelineTests: animations applied on \(animatedSVGCount)/\(fixtures.count) SVGs")

        XCTAssertGreaterThan(animatedSVGCount, 0, "Expected at least one SVG to receive animations.")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testAllSVGsFullPipeline() throws {
        let fixtures = try loadAllSVGFixtures()
        var failures: [String] = []

        for fixture in fixtures {
            let (_, rootLayer) = runFullPipeline(for: fixture)

            if rootLayer.frame != CGRect(x: 0, y: 0, width: 200, height: 200) {
                failures.append("\(fixture.filename): full pipeline produced unexpected frame \(rootLayer.frame)")
            }

            if rootLayer.sublayers?.isEmpty ?? true {
                failures.append("\(fixture.filename): full pipeline produced no sublayers")
            }

            switch fixture.filename {
            case "clawd-idle-follow.svg":
                if findLayer(named: "eyes-js", in: rootLayer) == nil {
                    failures.append("\(fixture.filename): missing named layer eyes-js")
                }
                if findLayer(named: "body-js", in: rootLayer) == nil,
                   findLayer(named: "body", in: rootLayer) == nil {
                    failures.append("\(fixture.filename): missing named layer body/body-js")
                }
                if findLayer(named: "shadow-js", in: rootLayer) == nil,
                   findLayer(named: "shadow", in: rootLayer) == nil {
                    failures.append("\(fixture.filename): missing named layer shadow/shadow-js")
                }
            case "clawd-mini-idle.svg":
                if findLayer(named: "eyes-js", in: rootLayer) == nil {
                    failures.append("\(fixture.filename): missing named layer eyes-js")
                }
                if findLayer(named: "body-js", in: rootLayer) == nil,
                   findLayer(named: "body", in: rootLayer) == nil {
                    failures.append("\(fixture.filename): missing named layer body/body-js")
                }
            default:
                break
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testHitTestOnAllSVGs() throws {
        let fixtures = try loadAllSVGFixtures()
        var failures: [String] = []

        for fixture in fixtures {
            let (_, rootLayer) = runFullPipeline(for: fixture)
            let centerPoint = CGPoint(x: rootLayer.bounds.midX, y: rootLayer.bounds.midY)

            _ = CALayerRenderer.hitTest(point: centerPoint, in: rootLayer)

            if rootLayer.sublayers?.isEmpty ?? true {
                failures.append("\(fixture.filename): hitTest ran on an empty layer tree")
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func loadAllSVGFixtures(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [SVGFixture] {
        let actualFilenames = try FileManager.default.contentsOfDirectory(atPath: Self.svgDirectoryURL.path)
            .filter { $0.hasSuffix(".svg") }
            .sorted()

        XCTAssertFalse(actualFilenames.isEmpty, "Expected at least one SVG in Resources/svg.", file: file, line: line)

        return try actualFilenames.map { filename in
            let fileURL = Self.svgDirectoryURL.appendingPathComponent(filename, isDirectory: false)
            let markup = try String(contentsOf: fileURL, encoding: .utf8)
            return SVGFixture(filename: filename, markup: markup)
        }
    }

    private func runFullPipeline(for fixture: SVGFixture) -> (SVGDocument, CALayer) {
        let document = SVGParser.parse(fixture.markup)
        let rootLayer = CALayerRenderer.build(document)
        CAAnimationBuilder.apply(document, to: rootLayer)
        rootLayer.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        return (document, rootLayer)
    }

    private func totalAnimationCount(in layer: CALayer) -> Int {
        let ownCount = layer.animationKeys()?.count ?? 0
        let childCount = (layer.sublayers ?? []).reduce(0) { partialResult, sublayer in
            partialResult + totalAnimationCount(in: sublayer)
        }
        return ownCount + childCount
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
}
