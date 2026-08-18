import Foundation
import SproutEngine

/// One recorded state change for an agent, for the transition log.
struct AgentTransition: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    let kind: String  // the hook event name
    let tool: String?
    let state: AgentState
}

/// A launched agent and its live, hook-derived state. `token` is the correlation
/// key baked into the hook URL; `sessionID` is filled once Claude's first hook
/// arrives. `consoleID` links to the PTY session so the UI can show/steer it.
struct AgentRuntime: Identifiable, Equatable {
    let id: UUID
    let branch: String
    let name: String
    let token: String
    var consoleID: UUID?
    var sessionID: String?
    var state: AgentState = .idle
    var currentTool: String?
    var transitions: [AgentTransition] = []

    /// `branch/name`, the human label for this agent.
    var label: String { "\(branch)/\(name)" }
}
