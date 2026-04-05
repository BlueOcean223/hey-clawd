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
