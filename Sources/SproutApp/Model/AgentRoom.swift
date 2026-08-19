import SproutEngine
import SwiftUI

/// A room on the agent-world floor. An agent's `AgentState` maps to exactly one
/// room; moving between rooms is how the world visualizes a state change.
enum AgentRoom: CaseIterable, Hashable {
    case desks  // actively working (thinking / running a tool)
    case waiting  // needs a human (approval prompt or error)
    case lounge  // idle, awaiting a prompt
    case done  // finished its turn
    case offline  // session ended

    /// The room an agent in `state` belongs in.
    static func of(_ state: AgentState) -> AgentRoom {
        switch state {
        case .thinking, .runningTool: return .desks
        case .waitingApproval, .error: return .waiting
        case .idle: return .lounge
        case .done: return .done
        case .ended: return .offline
        }
    }

    var title: String {
        switch self {
        case .desks: return "Desks"
        case .waiting: return "Waiting"
        case .lounge: return "Lounge"
        case .done: return "Done"
        case .offline: return "Offline"
        }
    }

    var systemImage: String {
        switch self {
        case .desks: return "desktopcomputer"
        case .waiting: return "exclamationmark.bubble"
        case .lounge: return "cup.and.saucer"
        case .done: return "checkmark.seal"
        case .offline: return "moon.zzz"
        }
    }
}
