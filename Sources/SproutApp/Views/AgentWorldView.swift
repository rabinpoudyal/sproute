import SproutEngine
import SwiftUI

/// The "office": every agent across all projects as an avatar that glides between
/// rooms (Desks / Waiting / Lounge / Done / Offline) as its state changes. Select
/// an avatar to inspect and steer it.
struct AgentWorldView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: UUID?

    private var agents: [WorldAgent] { app.allAgents() }
    private var selected: WorldAgent? { agents.first { $0.id == selection } }

    var body: some View {
        Group {
            if agents.isEmpty {
                ContentUnavailableView(
                    "No Agents Running", systemImage: "cpu",
                    description: Text("Start an agent in a workspace to see it here."))
            } else {
                FloorView(agents: agents, selection: $selection)
                    .padding(12)
            }
        }
        .navigationTitle("Agent World")
        .inspector(
            isPresented: Binding(
                get: { selected != nil }, set: { if !$0 { selection = nil } })
        ) {
            if let sel = selected {
                AgentInspector(
                    world: sel,
                    onSend: { app.sendAgentInput(projectID: sel.projectID, agentID: sel.id, $0) },
                    onStop: {
                        Task { await app.stopAgent(projectID: sel.projectID, agentID: sel.id) }
                    },
                    onOpenConsole: {
                        if let cid = sel.agent.consoleID {
                            openWindow(
                                value: ConsoleTarget(projectID: sel.projectID, sessionID: cid))
                        }
                    }
                )
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
            }
        }
    }
}

// MARK: - Floor

/// Lays out the rooms and positions each avatar by its room + index, so a state
/// change just moves the avatar's `.position` and SwiftUI animates the walk.
private struct FloorView: View {
    let agents: [WorldAgent]
    @Binding var selection: UUID?

    var body: some View {
        GeometryReader { geo in
            let plan = Self.layout(agents: agents, in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(AgentRoom.allCases, id: \.self) { room in
                    if let rect = plan.rooms[room] {
                        RoomView(room: room, count: plan.counts[room] ?? 0)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                ForEach(agents) { wa in
                    AgentAvatarView(agent: wa.agent, selected: selection == wa.id)
                        .position(plan.points[wa.id] ?? Self.center(geo.size))
                        .onTapGesture { selection = wa.id }
                        .animation(
                            .spring(response: 0.55, dampingFraction: 0.8),
                            value: plan.points[wa.id])
                }
            }
        }
    }

    private static func center(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Room rects (2×2 grid + a bottom Offline strip) and each agent's point.
    private static func layout(agents: [WorldAgent], in size: CGSize) -> Plan {
        let gap: CGFloat = 10
        let offlineH: CGFloat = 84
        let gridH = max(0, size.height - offlineH - gap)
        let colW = (size.width - gap) / 2
        let rowH = (gridH - gap) / 2
        var rooms: [AgentRoom: CGRect] = [
            .desks: CGRect(x: 0, y: 0, width: colW, height: rowH),
            .waiting: CGRect(x: colW + gap, y: 0, width: colW, height: rowH),
            .lounge: CGRect(x: 0, y: rowH + gap, width: colW, height: rowH),
            .done: CGRect(x: colW + gap, y: rowH + gap, width: colW, height: rowH),
        ]
        rooms[.offline] = CGRect(x: 0, y: gridH + gap, width: size.width, height: offlineH)

        var byRoom: [AgentRoom: [WorldAgent]] = [:]
        for wa in agents { byRoom[AgentRoom.of(wa.agent.state), default: []].append(wa) }

        var points: [UUID: CGPoint] = [:]
        var counts: [AgentRoom: Int] = [:]
        for (room, members) in byRoom {
            guard let rect = rooms[room] else { continue }
            counts[room] = members.count
            let inner = rect.insetBy(dx: 14, dy: 14).offsetBy(dx: 0, dy: 12)  // leave header room
            let cellW: CGFloat = 72
            let cellH: CGFloat = 76
            let cols = max(1, Int(inner.width / cellW))
            for (i, wa) in members.enumerated() {
                let col = i % cols
                let row = i / cols
                points[wa.id] = CGPoint(
                    x: inner.minX + (CGFloat(col) + 0.5) * cellW,
                    y: inner.minY + (CGFloat(row) + 0.5) * cellH)
            }
        }
        return Plan(rooms: rooms, points: points, counts: counts)
    }

    struct Plan {
        let rooms: [AgentRoom: CGRect]
        let points: [UUID: CGPoint]
        let counts: [AgentRoom: Int]
    }
}

private struct RoomView: View {
    let room: AgentRoom
    let count: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .underPageBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Image(systemName: room.systemImage)
                    Text(room.title).fontWeight(.medium)
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(10)
            }
    }
}

// MARK: - Avatar

private struct AgentAvatarView: View {
    let agent: AgentRuntime
    let selected: Bool

    private var color: Color { AgentStyle.color(agent.state) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                // A soft "puck" the character stands on, tinted by state.
                Circle().fill(color.opacity(0.18))
                Circle().strokeBorder(color.opacity(0.55), lineWidth: 1.5)
                Image(systemName: AgentStyle.figure(agent.state))
                    .font(.system(size: 26))
                    .foregroundStyle(color)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 46, height: 46)
            .overlay(
                Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .opacity(agent.state == .ended ? 0.45 : 1)
            Text(agent.name)
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: 64)
        }
        .frame(width: 64)
        .contentShape(Rectangle())
    }
}

// MARK: - Inspector

private struct AgentInspector: View {
    let world: WorldAgent
    let onSend: (String) -> Void
    let onStop: () -> Void
    let onOpenConsole: () -> Void
    @State private var redirect = ""

    private var agent: AgentRuntime { world.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(AgentStyle.color(agent.state)).frame(width: 10, height: 10)
                Text(agent.label).font(.headline)
            }
            Text("\(world.projectName) · \(world.agent.branch)")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            LabeledContent("State", value: AgentStyle.label(agent))
            LabeledContent("Tool", value: agent.currentTool ?? "—")
            LabeledContent("Session", value: agent.sessionID ?? "—")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                LabeledContent(
                    "Runtime", value: Self.elapsed(from: agent.startedAt, to: context.date))
            }

            Divider()
            Text("Steer").font(.subheadline.bold())
            HStack {
                TextField("Send a prompt…", text: $redirect)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).disabled(trimmed.isEmpty)
            }
            HStack {
                Button("Approve") { onSend("\r") }
                    .help("Sends Return to accept a prompt (best-effort)")
                Button("Stop", role: .destructive, action: onStop)
                    .disabled(agent.state == .ended)
                Spacer()
                Button("Open console", action: onOpenConsole)
                    .disabled(agent.consoleID == nil)
            }

            Divider()
            Text("Transitions").font(.subheadline.bold())
            AgentTransitionLog(transitions: agent.transitions)
        }
        .padding()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var trimmed: String {
        redirect.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        onSend(trimmed + "\n")
        redirect = ""
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
