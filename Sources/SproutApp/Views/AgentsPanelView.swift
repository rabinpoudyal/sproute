import SproutEngine
import SwiftUI

/// Slice-1 agent surface: launch configured agents in this workspace, watch each
/// one's live hook-derived state, and read its transition log. The selected
/// agent's PTY is embedded so you can type prompts to drive it.
struct AgentsPanelView: View {
    @ObservedObject var project: ProjectStore
    let item: WorkspaceItem
    @State private var selection: UUID?

    private var branch: String { item.record.branch }
    private var agents: [AgentRuntime] { project.agents.filter { $0.branch == branch } }
    private var configured: [AgentConfig] { project.config.agents }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                launchBar
                Divider()
                agentList
            }
            .frame(width: 260)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: list side

    @ViewBuilder private var launchBar: some View {
        if configured.isEmpty {
            Text("No [[agent]] in .sprout.toml")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                ForEach(configured, id: \.name) { cfg in
                    Button {
                        Task { await project.startAgent(item, name: cfg.name) }
                    } label: {
                        Label("Start \(cfg.name)", systemImage: "play.circle")
                    }
                    .disabled(isRunning(cfg.name))
                }
                Spacer()
            }
            .padding(8)
        }
    }

    private func isRunning(_ name: String) -> Bool {
        agents.contains { $0.name == name && $0.state != .ended }
    }

    private var agentList: some View {
        List(selection: $selection) {
            ForEach(agents) { agent in
                HStack(spacing: 8) {
                    Circle()
                        .fill(AgentStyle.color(agent.state))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name)
                        Text(AgentStyle.label(agent))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .tag(agent.id)
            }
        }
        .listStyle(.inset)
    }

    // MARK: detail side

    @ViewBuilder private var detail: some View {
        if let id = selection, let agent = agents.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                if let controller = project.agentController(id: id) {
                    ConsoleView(controller: controller)
                        .frame(minHeight: 200)
                } else {
                    ContentUnavailableView(
                        "Agent ended", systemImage: "bolt.slash",
                        description: Text("This agent's session is no longer running.")
                    )
                    .frame(minHeight: 120)
                }
                Divider()
                AgentTransitionLog(transitions: agent.transitions)
                    .frame(minHeight: 100)
            }
        } else {
            ContentUnavailableView(
                "Select an Agent", systemImage: "cpu",
                description: Text("Start an agent, then pick it to watch its state."))
        }
    }

}
