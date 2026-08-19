import SproutEngine
import SwiftUI

/// Shared visual language for agents, used by both the workspace panel and the
/// Agent World, so a state always reads the same everywhere.
enum AgentStyle {
    static func color(_ state: AgentState) -> Color {
        switch state {
        case .idle: return .secondary
        case .thinking: return .blue
        case .runningTool: return .purple
        case .waitingApproval: return .orange
        case .done: return .green
        case .error: return .red
        case .ended: return .gray
        }
    }

    /// A person-silhouette (`figure.*`) posed to match the agent's state, so an
    /// avatar reads as a little character rather than an abstract icon.
    static func figure(_ state: AgentState) -> String {
        switch state {
        case .idle: return "figure.stand"
        case .thinking: return "figure.mind.and.body"
        case .runningTool: return "figure.walk"
        case .waitingApproval: return "figure.wave"
        case .done: return "figure.cooldown"
        case .error: return "figure.fall"
        case .ended: return "figure.stand"
        }
    }

    /// Short human label for an agent's current state (includes the tool name
    /// while a tool runs).
    static func label(_ agent: AgentRuntime) -> String {
        switch agent.state {
        case .runningTool: return agent.currentTool.map { "running \($0)" } ?? "running tool"
        case .waitingApproval: return "waiting for approval"
        default: return agent.state.rawValue
        }
    }
}

/// Newest-first log of an agent's state transitions.
struct AgentTransitionLog: View {
    let transitions: [AgentTransition]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(transitions.reversed()) { t in
                    HStack(spacing: 8) {
                        Text(Self.time.string(from: t.at)).foregroundStyle(.secondary)
                        Text(t.kind)
                        if let tool = t.tool {
                            Text("(\(tool))").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(t.state.rawValue).foregroundStyle(AgentStyle.color(t.state))
                    }
                    .font(.caption.monospaced())
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
