import Foundation
import XCTest
@testable import HeyClawdApp

final class CodexMonitorTests: XCTestCase {
    func testHistoricalSessionIsRediscoveredOnNextScanAfterStaleCleanup() async throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectoryURL) }

        let now = Date()
        let historicalDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: now) ?? now
        let fileURL = try makeSessionFileURL(
            homeDirectoryURL: homeDirectoryURL,
            date: historicalDate,
            fileName: "rollout-history-11111-22222-33333-44444-55555.jsonl"
        )

        try writeLines(
            [
                jsonLine(type: "session_meta", payload: ["cwd": "/tmp/cross-midnight"]),
                jsonLine(type: "event_msg", payload: ["type": "task_started"]),
            ],
            to: fileURL
        )

        let attentionUpdate = expectation(description: "historical rollout resumed")
        let monitor = CodexMonitor(homeDirectoryURL: homeDirectoryURL)
        await monitor.setOnStateUpdate { update in
            guard update.state == .attention, update.event == "event_msg:task_complete" else {
                return
            }
            attentionUpdate.fulfill()
        }

        await monitor.scan(referenceTime: now)
        await monitor.expireStaleFiles(referenceTime: now.addingTimeInterval(301))

        try appendLines(
            [
                jsonLine(type: "response_item", payload: ["type": "function_call"]),
                jsonLine(type: "event_msg", payload: ["type": "task_complete"]),
            ],
            to: fileURL
        )

        await monitor.scan(referenceTime: Date())
        await fulfillment(of: [attentionUpdate], timeout: 1.0)
        await monitor.stop()
    }

    func testBootstrapCatchUpRestoresToolUseContextBeforeTaskComplete() async throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectoryURL) }

        let now = Date()
        let fileURL = try makeSessionFileURL(
            homeDirectoryURL: homeDirectoryURL,
            date: now,
            fileName: "rollout-bootstrap-aaaaa-bbbbb-ccccc-ddddd-eeeee.jsonl"
        )

        let filler = String(repeating: "x", count: 256)
        var lines = [
            jsonLine(type: "session_meta", payload: ["cwd": "/tmp/large-rollout"]),
            jsonLine(type: "event_msg", payload: ["type": "task_started"]),
            jsonLine(type: "response_item", payload: ["type": "function_call"]),
        ]
        lines.append(
            contentsOf: (0 ..< 1_400).map { index in
                jsonLine(
                    type: "event_msg",
                    payload: ["type": "agent_message", "text": "\(index)-\(filler)"]
                )
            }
        )
        lines.append(jsonLine(type: "event_msg", payload: ["type": "task_complete"]))
        try writeLines(lines, to: fileURL)

        let attentionUpdate = expectation(description: "initial bootstrap resolves attention")
        let monitor = CodexMonitor(homeDirectoryURL: homeDirectoryURL)
        await monitor.setOnStateUpdate { update in
            guard update.state == .attention, update.event == "event_msg:task_complete" else {
                return
            }
            attentionUpdate.fulfill()
        }

        await monitor.scan(referenceTime: now)
        await fulfillment(of: [attentionUpdate], timeout: 1.0)
        await monitor.stop()
    }

    private func makeTemporaryHomeDirectory() throws -> URL {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func makeSessionFileURL(homeDirectoryURL: URL, date: Date, fileName: String) throws -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let directoryURL = homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(components.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day ?? 0), isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        return fileURL
    }

    private func writeLines(_ lines: [String], to fileURL: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: fileURL)
    }

    private func appendLines(_ lines: [String], to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func jsonLine(type: String, payload: [String: Any]) -> String {
        let object: [String: Any] = [
            "type": type,
            "payload": payload,
        ]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data ?? Data(), as: UTF8.self)
    }
}
