import Foundation
import XCTest
@testable import HeyClawdApp

@MainActor
final class StateMachineSessionFocusTests: XCTestCase {
    func testAgentPidAncestryDoesNotBypassTerminalBundleWhitelist() {
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
            sessionId: "ancestry-session",
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
        XCTAssertEqual(session?.sourcePidVerified, false)
        XCTAssertEqual(session?.focusTarget.identity, identity)
        XCTAssertEqual(session?.focusTarget.isSourceVerified, false)
    }

    func testSessionFocusTargetRejectsAgentPidAsItsOwnVerifiedSource() {
        let identity = FocusProcessIdentity(
            pid: 200,
            bundleIdentifier: "dev.example.UnknownAgent",
            executablePath: "/usr/local/bin/unknown-agent",
            launchDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let inspector = FakeProcessInspector(
            alivePids: [100, 200],
            parentPids: [200: 100, 100: 1],
            identities: [200: identity]
        )
        let stateMachine = StateMachine(processInspector: inspector)
        defer { stateMachine.cleanup() }

        stateMachine.setState(
            .working,
            sessionId: "self-source",
            event: "PreToolUse",
            sourcePid: 200,
            agentPid: 200,
            pidChain: [200, 100],
            cwd: "/tmp/project",
            agentId: "claude-code"
        )

        let session = stateMachine.activeSessionSnapshots.first
        XCTAssertEqual(session?.sourcePid, 200)
        XCTAssertEqual(session?.agentPid, 200)
        XCTAssertEqual(session?.sourceProcessIdentity, identity)
        XCTAssertEqual(session?.sourcePidVerified, false)
        XCTAssertEqual(session?.focusTarget.isSourceVerified, false)
    }

    func testProcessIdentityRequiresCurrentLaunchDateWhenLaunchDateWasCaptured() {
        let identity = FocusProcessIdentity(
            pid: 100,
            bundleIdentifier: nil,
            executablePath: nil,
            launchDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertFalse(
            identity.matches(
                pid: 100,
                isTerminated: false,
                bundleIdentifier: nil,
                executablePath: nil,
                launchDate: nil
            )
        )
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
