import Foundation
import XCTest
@testable import HeyClawdApp

@MainActor
final class StateMachineSessionFocusTests: XCTestCase {
    func testSessionFocusTargetUsesVerifiedAgentAncestryInsteadOfTerminalBundleWhitelist() {
        let identity = FocusProcessIdentity(
            pid: 100,
            bundleIdentifier: "dev.example.UnknownTerminal",
            executablePath: "/Applications/UnknownTerminal.app/Contents/MacOS/UnknownTerminal",
            launchDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let inspector = FakeProcessInspector(
            alivePids: [100, 150, 200],
            parentPids: [200: 150, 150: 100, 100: 1],
            identities: [100: identity]
        )
        let stateMachine = StateMachine(processInspector: inspector)
        defer { stateMachine.cleanup() }

        stateMachine.setState(
            .working,
            sessionId: "verified-session",
            event: "PreToolUse",
            sourcePid: 100,
            agentPid: 200,
            pidChain: [200, 150, 100],
            cwd: "/tmp/project",
            agentId: "claude-code"
        )

        let session = stateMachine.activeSessionSnapshots.first
        XCTAssertEqual(session?.sourcePid, 100)
        XCTAssertEqual(session?.agentPid, 200)
        XCTAssertEqual(session?.pidChain, [200, 150, 100])
        XCTAssertEqual(session?.sourceProcessIdentity, identity)
        XCTAssertEqual(session?.sourcePidVerified, true)
        XCTAssertEqual(session?.focusTarget.identity, identity)
        XCTAssertEqual(session?.focusTarget.isSourceVerified, true)
    }

    func testDeadAgentPidRemovesSessionWithoutWaitingForAgeTimeout() {
        let identity = FocusProcessIdentity(
            pid: 100,
            bundleIdentifier: "dev.example.UnknownTerminal",
            executablePath: "/Applications/UnknownTerminal.app/Contents/MacOS/UnknownTerminal",
            launchDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let inspector = FakeProcessInspector(
            alivePids: [100, 200],
            parentPids: [200: 100, 100: 1],
            identities: [100: identity]
        )
        let stateMachine = StateMachine(processInspector: inspector)
        defer { stateMachine.cleanup() }

        stateMachine.setState(
            .working,
            sessionId: "agent-exits",
            event: "PreToolUse",
            sourcePid: 100,
            agentPid: 200,
            pidChain: [200, 100],
            cwd: "/tmp/project",
            agentId: "claude-code"
        )
        XCTAssertEqual(stateMachine.activeSessionSnapshots.count, 1)

        inspector.alivePids = [100]
        stateMachine.pruneStaleSessionsForTesting()

        XCTAssertTrue(stateMachine.activeSessionSnapshots.isEmpty)
    }
}

@MainActor
private final class FakeProcessInspector: ProcessInspecting {
    var alivePids: Set<pid_t>
    var parentPids: [pid_t: pid_t]
    var identities: [pid_t: FocusProcessIdentity]

    init(
        alivePids: Set<pid_t>,
        parentPids: [pid_t: pid_t],
        identities: [pid_t: FocusProcessIdentity]
    ) {
        self.alivePids = alivePids
        self.parentPids = parentPids
        self.identities = identities
    }

    func captureApplicationIdentity(for pid: pid_t) -> FocusProcessIdentity? {
        identities[pid]
    }

    func isProcessAlive(_ pid: pid_t) -> Bool {
        alivePids.contains(pid)
    }

    func parentPid(of pid: pid_t) -> pid_t? {
        parentPids[pid]
    }
}
