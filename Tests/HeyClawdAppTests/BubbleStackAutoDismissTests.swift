import AppKit
import Foundation
import XCTest
@testable import HeyClawdApp

@MainActor
final class BubbleStackAutoDismissTests: XCTestCase {
    func testUniqueMatchDismissesOneBubble() async throws {
        let stack = makeStack()
        let fixture = try makeFixture(sessionId: "session-1", toolName: "Bash", command: "ls")
        let task = enqueue(fixture, in: stack)

        let dismissed = stack.dismissBubbleMatchingTerminalApproval(
            sessionId: "session-1",
            toolName: "Bash",
            toolInputHash: try XCTUnwrap(fixture.content.toolInputHash)
        )

        XCTAssertTrue(dismissed)
        XCTAssertEqual(stack.pendingCount, 0)
        _ = await task.value
    }

    func testDifferentToolInputHashDoesNotDismiss() async throws {
        let stack = makeStack()
        let fixture = try makeFixture(sessionId: "session-1", toolName: "Bash", command: "ls")
        let other = try makeFixture(sessionId: "session-1", toolName: "Bash", command: "pwd")
        let task = enqueue(fixture, in: stack)

        let dismissed = stack.dismissBubbleMatchingTerminalApproval(
            sessionId: "session-1",
            toolName: "Bash",
            toolInputHash: try XCTUnwrap(other.content.toolInputHash)
        )

        XCTAssertFalse(dismissed)
        XCTAssertEqual(stack.pendingCount, 1)
        stack.dismissAll(respondingWith: .undecided)
        _ = await task.value
    }

    func testMultipleMatchesDoNotDismiss() async throws {
        let stack = makeStack()
        let first = try makeFixture(sessionId: "session-1", toolName: "Bash", command: "ls")
        let second = try makeFixture(sessionId: "session-1", toolName: "Bash", command: "ls")
        let firstTask = enqueue(first, in: stack)
        let secondTask = enqueue(second, in: stack)

        let dismissed = stack.dismissBubbleMatchingTerminalApproval(
            sessionId: "session-1",
            toolName: "Bash",
            toolInputHash: try XCTUnwrap(first.content.toolInputHash)
        )

        XCTAssertFalse(dismissed)
        XCTAssertEqual(stack.pendingCount, 2)
        stack.dismissAll(respondingWith: .undecided)
        _ = await firstTask.value
        _ = await secondTask.value
    }

    func testSessionMismatchDoesNotDismiss() async throws {
        let stack = makeStack()
        let fixture = try makeFixture(sessionId: "session-1", toolName: "Bash", command: "ls")
        let task = enqueue(fixture, in: stack)

        let dismissed = stack.dismissBubbleMatchingTerminalApproval(
            sessionId: "session-2",
            toolName: "Bash",
            toolInputHash: try XCTUnwrap(fixture.content.toolInputHash)
        )

        XCTAssertFalse(dismissed)
        XCTAssertEqual(stack.pendingCount, 1)
        stack.dismissAll(respondingWith: .undecided)
        _ = await task.value
    }

    func testToolNameMismatchDoesNotDismiss() async throws {
        let stack = makeStack()
        let fixture = try makeFixture(sessionId: "session-1", toolName: "Bash", command: "ls")
        let task = enqueue(fixture, in: stack)

        let dismissed = stack.dismissBubbleMatchingTerminalApproval(
            sessionId: "session-1",
            toolName: "Read",
            toolInputHash: try XCTUnwrap(fixture.content.toolInputHash)
        )

        XCTAssertFalse(dismissed)
        XCTAssertEqual(stack.pendingCount, 1)
        stack.dismissAll(respondingWith: .undecided)
        _ = await task.value
    }

    func testMissingPendingToolInputHashDoesNotDismiss() async throws {
        let stack = makeStack()
        let fixture = try makeFixture(sessionId: "session-1", toolName: "Bash", command: nil)
        let other = try makeFixture(sessionId: "session-1", toolName: "Bash", command: "ls")
        let task = enqueue(fixture, in: stack)

        XCTAssertNil(fixture.content.toolInputHash)
        let dismissed = stack.dismissBubbleMatchingTerminalApproval(
            sessionId: "session-1",
            toolName: "Bash",
            toolInputHash: try XCTUnwrap(other.content.toolInputHash)
        )

        XCTAssertFalse(dismissed)
        XCTAssertEqual(stack.pendingCount, 1)
        stack.dismissAll(respondingWith: .undecided)
        _ = await task.value
    }

    func testDismissRespondsUndecided() async throws {
        let stack = makeStack()
        let fixture = try makeFixture(sessionId: "session-1", toolName: "Bash", command: "ls")
        let task = enqueue(fixture, in: stack)

        XCTAssertTrue(
            stack.dismissBubbleMatchingTerminalApproval(
                sessionId: "session-1",
                toolName: "Bash",
                toolInputHash: try XCTUnwrap(fixture.content.toolInputHash)
            )
        )

        let result = await task.value
        XCTAssertEqual(result.behavior.rawValue, PermissionBehavior.undecided.rawValue)
    }

    private func makeStack() -> BubbleStack {
        _ = NSApplication.shared
        return BubbleStack(
            petWindowProvider: { nil },
            bubbleFollowProvider: { false }
        )
    }

    private func enqueue(
        _ fixture: PermissionFixture,
        in stack: BubbleStack
    ) -> Task<PermissionDecisionResult, Never> {
        let pending = makePendingRequest(body: fixture.body)
        stack.enqueue(content: fixture.content, request: pending.request)
        return pending.resultTask
    }

    private func makePendingRequest(
        body: Data
    ) -> (request: PendingPermissionRequest, resultTask: Task<PermissionDecisionResult, Never>) {
        let box = PendingPermissionRequestBox()
        let resultTask = Task.detached {
            await withCheckedContinuation { continuation in
                let request = PendingPermissionRequest(body: body, continuation: continuation)
                box.store(request)
            }
        }

        return (box.wait(), resultTask)
    }

    private func makeFixture(
        sessionId: String,
        toolName: String,
        command: String?
    ) throws -> PermissionFixture {
        var payload: [String: Any] = [
            "session_id": sessionId,
            "tool_name": toolName,
        ]

        if let command {
            payload["tool_input"] = ["command": command]
        }

        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let content = try XCTUnwrap(PermissionBubbleContent.decode(from: body))
        return PermissionFixture(body: body, content: content)
    }
}

private struct PermissionFixture {
    let body: Data
    let content: PermissionBubbleContent
}

private final class PendingPermissionRequestBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var request: PendingPermissionRequest?

    func store(_ request: PendingPermissionRequest) {
        lock.withLock {
            self.request = request
        }
        semaphore.signal()
    }

    func wait() -> PendingPermissionRequest {
        semaphore.wait()
        return lock.withLock {
            guard let request else {
                fatalError("PendingPermissionRequest was not created")
            }
            return request
        }
    }
}
