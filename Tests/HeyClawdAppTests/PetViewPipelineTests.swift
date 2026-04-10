import Foundation
import CoreGraphics
import QuartzCore
import XCTest
@testable import HeyClawdApp

@MainActor
final class PetViewPipelineTests: XCTestCase {
    private static let allSVGFilenames = [
        "clawd-collapse-sleep.svg",
        "clawd-crab-walking.svg",
        "clawd-disconnected.svg",
        "clawd-dizzy.svg",
        "clawd-error.svg",
        "clawd-going-away.svg",
        "clawd-happy.svg",
        "clawd-idle-collapse.svg",
        "clawd-idle-doze.svg",
        "clawd-idle-follow.svg",
        "clawd-idle-living.svg",
        "clawd-idle-look.svg",
        "clawd-idle-music.svg",
        "clawd-idle-reading.svg",
        "clawd-idle-yawn.svg",
        "clawd-mini-alert.svg",
        "clawd-mini-crabwalk.svg",
        "clawd-mini-enter-sleep.svg",
        "clawd-mini-enter.svg",
        "clawd-mini-happy.svg",
        "clawd-mini-idle.svg",
        "clawd-mini-peek-up.svg",
        "clawd-mini-peek.svg",
        "clawd-mini-sleep.svg",
        "clawd-notification.svg",
        "clawd-react-annoyed.svg",
        "clawd-react-double-jump.svg",
        "clawd-react-double.svg",
        "clawd-react-drag.svg",
        "clawd-react-left.svg",
        "clawd-react-right.svg",
        "clawd-react-salute.svg",
        "clawd-sleeping.svg",
        "clawd-static-base.svg",
        "clawd-wake.svg",
        "clawd-working-beacon.svg",
        "clawd-working-builder.svg",
        "clawd-working-building.svg",
        "clawd-working-carrying.svg",
        "clawd-working-conducting.svg",
        "clawd-working-confused.svg",
        "clawd-working-debugger.svg",
        "clawd-working-juggling.svg",
        "clawd-working-overheated.svg",
        "clawd-working-pushing.svg",
        "clawd-working-success.svg",
        "clawd-working-sweeping.svg",
        "clawd-working-thinking.svg",
        "clawd-working-typing.svg",
        "clawd-working-ultrathink.svg",
        "clawd-working-wizard.svg",
    ]

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

        XCTAssertEqual(actualFilenames, Self.allSVGFilenames, "Static SVG inventory is out of sync with Resources/svg.", file: file, line: line)

        return try Self.allSVGFilenames.map { filename in
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
