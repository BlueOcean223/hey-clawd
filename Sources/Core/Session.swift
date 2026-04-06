import Foundation

struct Session: Sendable {
    let id: String
    var state: PetState
    var updatedAt: Date
    var displaySvg: String?
    var sourcePid: pid_t?
    var cwd: String?
    var editor: FocusEditor?
    var agentId: String?
    var headless: Bool
}

struct SessionMenuSnapshot: Sendable {
    let id: String
    let state: PetState
    let updatedAt: Date
    let sourcePid: pid_t?
    let cwd: String?
    let editor: FocusEditor?
    let agentId: String?

    var focusTarget: TerminalFocusTarget {
        TerminalFocusTarget(pid: sourcePid, editor: editor)
    }
}
