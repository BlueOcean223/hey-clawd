import Foundation
import XCTest
@testable import HeyClawdApp

final class StateMachineAnimationTests: XCTestCase {
    private static var svgDirectoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("svg", isDirectory: true)
    }

    @MainActor
    func testIdleAnimationSafeExitDurations() {
        let expectedDurations = [
            "clawd-idle-look.svg": 10_000,
            "clawd-working-debugger.svg": 14_000,
            "clawd-idle-reading.svg": 14_000,
            "clawd-idle-living.svg": 16_000,
            "clawd-idle-music.svg": 9_600,
            "clawd-idle-smoking.svg": 16_000,
            "clawd-crab-walking.svg": 8_000,
        ]

        let actualDurations = Dictionary(
            uniqueKeysWithValues: StateMachine.idleAnims.map { ($0.svg, $0.durationMs) }
        )

        XCTAssertEqual(actualDurations, expectedDurations)
    }

    @MainActor
    func testIdleSafeExitDurationsMatchMainSVGTimelines() throws {
        let timelineBoundSVGs: Set<String> = [
            "clawd-idle-look.svg",
            "clawd-working-debugger.svg",
            "clawd-idle-reading.svg",
            "clawd-idle-living.svg",
            "clawd-idle-music.svg",
            "clawd-idle-smoking.svg",
        ]

        for spec in StateMachine.idleAnims where timelineBoundSVGs.contains(spec.svg) {
            let document = SVGParser.parse(try loadSVG(spec.svg))
            let longestDuration = document.animationBindings.map(\.duration).max() ?? 0

            XCTAssertEqual(
                Double(spec.durationMs) / 1000.0,
                longestDuration,
                accuracy: 0.001,
                "\(spec.svg) should return to idle only after its main timeline has reached a neutral exit."
            )
        }
    }

    private func loadSVG(_ filename: String) throws -> String {
        let fileURL = Self.svgDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
