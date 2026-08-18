import Testing

@testable import SproutEngine

@Suite struct AgentStateReducerTests {
    private func reduce(_ kind: String, tool: String? = nil, from: AgentState = .idle)
        -> AgentState
    {
        AgentStateReducer.state(
            for: AgentEvent(sessionID: "s", kind: kind, tool: tool), previous: from)
    }

    @Test func mapsCoreEvents() {
        #expect(reduce("SessionStart") == .idle)
        #expect(reduce("UserPromptSubmit") == .thinking)
        #expect(reduce("PreToolUse", tool: "Edit") == .runningTool)
        #expect(reduce("PostToolUse") == .thinking)
        #expect(reduce("PostToolUseFailure") == .error)
        #expect(reduce("Notification") == .waitingApproval)
        #expect(reduce("PermissionRequest") == .waitingApproval)
        #expect(reduce("Stop") == .done)
        #expect(reduce("SessionEnd") == .ended)
    }

    @Test func unknownEventKeepsPreviousState() {
        #expect(reduce("SomeFutureHook", from: .runningTool) == .runningTool)
    }
}
