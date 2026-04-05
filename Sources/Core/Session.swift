import Foundation

struct Session: Sendable {
    let id: String
    var state: PetState
    var updatedAt: Date
    var displaySvg: String?
    var sourcePid: pid_t?
    var cwd: String?
    var agentId: String?
    var headless: Bool
}

struct SessionMenuSnapshot: Sendable {
    let id: String
    let state: PetState
    let updatedAt: Date
    let sourcePid: pid_t?
    let cwd: String?
    let agentId: String?
}
