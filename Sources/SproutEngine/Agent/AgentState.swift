import Foundation

/// The coarse lifecycle state of a Claude Code agent, derived from its hook
/// callbacks. Deliberately small: this is what a glanceable multi-agent view
/// needs, not a faithful replay of the transcript.
public enum AgentState: String, Sendable, Codable, Equatable {
    case idle  // session started / turn finished, awaiting input
    case thinking  // prompt submitted, model working
    case runningTool  // a tool call is executing
    case waitingApproval  // blocked on a permission prompt or idle notification
    case done  // the model finished responding (turn complete)
    case error  // a tool failed or the agent reported an error
    case ended  // the session ended / process exited
}

/// A single decoded hook callback from a Claude Code session. Only the fields we
/// act on are kept; the raw payload carries far more we intentionally drop.
public struct AgentEvent: Sendable, Equatable {
    /// Claude's own `session_id` — stable for the life of one `claude` session.
    public let sessionID: String
    /// The hook event name (`hook_event_name`), e.g. "PreToolUse". We key state
    /// transitions off this string and tolerate names we don't recognize.
    public let kind: String
    /// `tool_name` when the event carries one (PreToolUse/PostToolUse).
    public let tool: String?
    /// A human-readable message when present (Notification/Stop).
    public let message: String?

    public init(sessionID: String, kind: String, tool: String? = nil, message: String? = nil) {
        self.sessionID = sessionID
        self.kind = kind
        self.tool = tool
        self.message = message
    }
}
