import Foundation

/// Maps a hook event onto the next `AgentState`. Pure and total: an event name we
/// don't recognize leaves the state unchanged, so a future Claude Code that adds
/// or renames hooks degrades gracefully instead of breaking.
public enum AgentStateReducer {
    public static func state(for event: AgentEvent, previous: AgentState) -> AgentState {
        switch event.kind {
        case "SessionStart":
            return .idle
        case "UserPromptSubmit":
            return .thinking
        case "PreToolUse":
            return .runningTool
        // A tool finished — back to the model working until the next signal.
        case "PostToolUse", "PostToolUseFailure":
            return event.kind == "PostToolUseFailure" ? .error : .thinking
        // The agent is blocked waiting on the human: a permission prompt or an
        // idle notification. This is the state a human most needs to see.
        case "Notification", "PermissionRequest":
            return .waitingApproval
        case "Stop":
            return .done
        case "SessionEnd":
            return .ended
        default:
            return previous
        }
    }
}
