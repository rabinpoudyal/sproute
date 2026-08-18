import SwiftUI
import SproutEngine

/// Read-only overview of a project's workspaces: headline stat cards plus a
/// per-workspace strip. All metrics derive from the already-reconciled
/// `ProjectStore.workspaces` — no new engine plumbing.
struct ProjectDashboard: View {
    @ObservedObject var project: ProjectStore
    let onNewWorkspace: () -> Void

    private var items: [WorkspaceItem] { project.workspaces }
    private var running: Int { items.filter { $0.record.status == .running }.count }
    private var crashed: Int { items.filter { $0.record.status == .crashed }.count }
    private var portsUsed: Int { Set(items.map { $0.record.port }).count }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No Workspaces", systemImage: "square.stack.3d.up.slash")
                } description: {
                    Text("Create a worktree to spin up an isolated dev workspace.")
                } actions: {
                    Button("New Workspace", action: onNewWorkspace)
                }
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    statGrid
                    workspaceStrip
                }
                .padding(20)
            }
        }
    }

    private var statGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            StatCard(
                title: "Workspaces", value: "\(items.count)",
                systemImage: "square.stack.3d.up", tint: .accentColor)
            StatCard(
                title: "Running", value: "\(running)",
                systemImage: "bolt.fill", tint: .green)
            StatCard(
                title: "Crashed", value: "\(crashed)",
                systemImage: "exclamationmark.triangle.fill",
                tint: crashed > 0 ? .red : .secondary)
            StatCard(
                title: "Ports in use", value: "\(portsUsed)",
                systemImage: "network", tint: .blue)
        }
    }

    private var workspaceStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspaces")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    WorkspaceStripRow(item: item, processCount: project.config.run.processes.count)
                    if item.id != items.last?.id { Divider() }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// One headline metric tile.
private struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One workspace row in the dashboard strip: status, branch, port, process
/// health, and age.
private struct WorkspaceStripRow: View {
    let item: WorkspaceItem
    let processCount: Int

    private var rec: WorkspaceRecord { item.record }
    private var processesUp: Int { rec.processes.filter { $0.status == .running }.count }

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(status: rec.status, showText: false)
            Text(rec.branch)
                .fontWeight(.medium)
                .opacity(item.orphaned ? 0.5 : 1)
            if item.orphaned {
                Text("orphaned")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text("\(processesUp)/\(processCount) up")
                .font(.caption.monospaced())
                .foregroundStyle(processesUp > 0 ? .primary : .secondary)
            Text(":\(rec.port)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(rec.createdAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
