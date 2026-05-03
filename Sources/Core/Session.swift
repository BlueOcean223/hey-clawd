import Foundation

struct Session: Sendable {
    let id: String
    var state: PetState
    var updatedAt: Date
    var displaySvg: String?
    var sourcePid: pid_t?
    var sourceProcessIdentity: FocusProcessIdentity?
    var sourcePidVerified: Bool
    var agentPid: pid_t?
    var pidChain: [pid_t]?
    var cwd: String?
    var editor: FocusEditor?
    var agentId: String?
    var headless: Bool

    var focusTarget: TerminalFocusTarget {
        TerminalFocusTarget(
            pid: sourcePid,
            identity: sourceProcessIdentity,
            isSourceVerified: sourcePidVerified,
            pidChain: pidChain,
            editor: editor
        )
    }
}

struct SessionMenuSnapshot: Sendable {
    let id: String
    let state: PetState
    let updatedAt: Date
    let sourcePid: pid_t?
    let sourceProcessIdentity: FocusProcessIdentity?
    let sourcePidVerified: Bool
    let agentPid: pid_t?
    let pidChain: [pid_t]?
    let cwd: String?
    let editor: FocusEditor?
    let agentId: String?

    var focusTarget: TerminalFocusTarget {
        TerminalFocusTarget(
            pid: sourcePid,
            identity: sourceProcessIdentity,
            isSourceVerified: sourcePidVerified,
            pidChain: pidChain,
            editor: editor
        )
    }
}
