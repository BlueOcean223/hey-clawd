import Foundation
import XCTest
@testable import HeyClawdApp

final class PermissionMatchKeyTests: XCTestCase {
    func testMatchesSharedFixtures() throws {
        for fixture in try loadFixtures() {
            let name = try XCTUnwrap(fixture["name"] as? String)
            let input = try XCTUnwrap(fixture["input"])
            let expected = try XCTUnwrap(fixture["expected"] as? String)

            XCTAssertEqual(PermissionMatchKey.hashToolInput(input), expected, name)
        }
    }

    func testObjectKeyOrderIsStable() {
        XCTAssertEqual(
            PermissionMatchKey.hashToolInput(["a": 1, "b": 2] as [String: Any]),
            PermissionMatchKey.hashToolInput(["b": 2, "a": 1] as [String: Any])
        )
    }

    func testArrayOrderAffectsHash() {
        XCTAssertNotEqual(
            PermissionMatchKey.hashToolInput([1, 2, 3]),
            PermissionMatchKey.hashToolInput([3, 2, 1])
        )
    }

    func testEmptyObjectHashIsStable() {
        XCTAssertEqual(
            PermissionMatchKey.hashToolInput([String: Any]()),
            "sha256:v1:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
        )
    }

    private func loadFixtures() throws -> [[String: Any]] {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "match-key-fixtures",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}
