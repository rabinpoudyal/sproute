import SproutEngine
import SwiftUI

struct WorkspaceDetailView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var project: ProjectStore
    let item: WorkspaceItem
    @Binding var drawerVisible: Bool
    @Binding var drawerHeight: Double

    @State private var busy = false
    @State private var confirmDone = false
    @State private var confirmDiscard = false
    @State private var dirtyWarning = false
    @State private var selectedProcess: String?
    @State private var showInspector = true
    @State private var pane: Pane = .processes

    private enum Pane: Hashable { case processes, agents }

    private var rec: WorkspaceRecord { item.record }
    private var processNames: [String] { project.config.run.processes.map(\.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $pane) {
                Text("Processes").tag(Pane.processes)
                Text("Agents").tag(Pane.agents)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(8)
            Divider()
            if pane == .agents {
                AgentsPanelView(project: project, item: item)
            } else {
                mainContent
            }
            if drawerVisible {
                Divider()
                ShellDrawer(
                    project: project, item: item,
                    height: Binding(
                        get: { CGFloat(drawerHeight) },
                        set: { drawerHeight = Double($0) }),
                    onClose: { drawerVisible = false })
            }
        }
        .navigationTitle(project.name)
        .navigationSubtitle(rec.branch)
        .inspector(isPresented: $showInspector) {
            ProcessListView(
                project: project, item: item, busy: $busy, selection: $selectedProcess
            )
            .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Tear down \(rec.branch)?",
            isPresented: $confirmDone, titleVisibility: .visible
        ) {
            Button("Push & Tear Down", role: .destructive) {
                run { await tearDown(push: true, force: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Pushes the branch, then removes the worktree, drops the database, and deletes the branch."
            )
        }
        .confirmationDialog(
            "Discard \(rec.branch)?",
            isPresented: $confirmDiscard, titleVisibility: .visible
        ) {
            Button("Discard Permanently", role: .destructive) {
                run { await tearDown(push: false, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Destroys the worktree, database, and branch WITHOUT pushing. Unmerged commits are lost."
            )
        }
        .alert("Uncommitted changes", isPresented: $dirtyWarning) {
            Button("Force Tear Down", role: .destructive) {
                run { await tearDown(push: true, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This worktree has uncommitted changes. Tear down anyway?")
        }
        .alert(
            project.lastError?.title ?? "Something went wrong",
            isPresented: Binding(
                get: { project.lastError != nil },
                set: { if !$0 { project.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let detail = project.lastError?.detail {
                Text(detail)
            }
        }
    }

    // MARK: main content

    /// The logs of the process selected in the inspector list, or a prompt when
    /// nothing is selected.
    @ViewBuilder private var mainContent: some View {
        if let name = selectedProcess, processNames.contains(name) {
            ProcessDetailView(project: project, item: item, name: name, busy: $busy)
        } else {
            ContentUnavailableView(
                "Select a Process", systemImage: "list.bullet.rectangle",
                description: Text("Pick a process from the list to view its logs."))
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Reveal in Finder") { project.revealInFinder(item) }
                Button("Open in Editor") { project.openInEditor(item) }
                Button("Open in Browser") { project.openInBrowser(item) }
                Divider()
                Button("Push") { run { await project.push(item) } }
                Button("Done (push & tear down)") { confirmDone = true }
                Button("Discard…", role: .destructive) { confirmDiscard = true }
            } label: {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
            .help("More actions")
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Toggle inspector")
        }
    }

    // MARK: actions

    private func tearDown(push: Bool, force: Bool) async {
        if push, !force, await project.isDirty(item) {
            dirtyWarning = true
            return
        }
        await project.teardown(item, push: push, force: force)
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }

}

// MARK: - Process list + detail

/// One row in the workspace process list: status dot, name, optional port badge,
/// and a single Start/Stop toggle that flips with the process's running state.
/// The row body is a NavigationLink (pushes detail); the button uses
/// `.borderless` so a tap hits the button, not the link.
private struct ProcessRow: View {
    let proc: ProcessConfig
    let status: ProcessStatus?
    let orphaned: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    private var isRunning: Bool { status == .running }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: 9))
                .foregroundStyle(statusColor)
                .accessibilityLabel("Status: \(statusLabel)")
            Text(proc.name)
            if let port = proc.port {
                Text(":\(port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: isRunning ? onStop : onStart) {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(isRunning ? "Stop" : "Start")
            .accessibilityLabel(isRunning ? "Stop \(proc.name)" : "Start \(proc.name)")
            .disabled(orphaned)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch status {
        case .running: return .green
        case .crashed: return .red
        default: return .secondary
        }
    }

    private var statusSymbol: String {
        switch status {
        case .running: return "circle.fill"
        case .crashed: return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private var statusLabel: String {
        switch status {
        case .running: return "Running"
        case .crashed: return "Crashed"
        default: return "Stopped"
        }
    }
}

/// Inspector list of a workspace's run processes. Selecting a row drives the
/// main content (that process's logs).
private struct ProcessListView: View {
    @ObservedObject var project: ProjectStore
    let item: WorkspaceItem
    @Binding var busy: Bool
    @Binding var selection: String?

    private var rec: WorkspaceRecord { item.record }
    private var processes: [ProcessConfig] { project.config.run.processes }

    var body: some View {
        Group {
            if processes.isEmpty {
                ContentUnavailableView(
                    "No processes", systemImage: "bolt.slash",
                    description: Text("This workspace defines no run processes."))
            } else {
                List(selection: $selection) {
                    ForEach(processes, id: \.name) { proc in
                        ProcessRow(
                            proc: proc,
                            status: status(of: proc.name),
                            orphaned: item.orphaned,
                            onStart: {
                                run { await project.startProcess(item, name: proc.name) }
                            },
                            onStop: {
                                run { await project.stopProcess(item, name: proc.name) }
                            }
                        )
                        .tag(proc.name)
                    }
                }
            }
        }
    }

    private func status(of name: String) -> ProcessStatus? {
        rec.processes.first(where: { $0.name == name })?.status
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}

/// Pushed page: one process's logs plus Start/Stop/Restart in the toolbar.
private struct ProcessDetailView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var project: ProjectStore
    let item: WorkspaceItem
    let name: String
    @Binding var busy: Bool

    private var rec: WorkspaceRecord { item.record }
    private var status: ProcessStatus? {
        rec.processes.first(where: { $0.name == name })?.status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(name).font(.headline)
                if let port = project.config.run.processes
                    .first(where: { $0.name == name })?.port
                {
                    Text(":\(port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 8)
            Divider()
            LogConsoleView(
                buffer: project.logBuffer(branch: rec.branch, process: name),
                onPopOut: {
                    openWindow(
                        value: LogTarget(projectID: project.id, branch: rec.branch, process: name))
                }
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if status == .running {
                        run { await project.stopProcess(item, name: name) }
                    } else {
                        run { await project.startProcess(item, name: name) }
                    }
                } label: {
                    Label(
                        status == .running ? "Stop" : "Start",
                        systemImage: status == .running ? "stop.fill" : "play.fill")
                }
                .disabled(item.orphaned)
                Button {
                    run { await project.restartProcess(item, name: name) }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .disabled(item.orphaned)
            }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}

// MARK: - Project overview (editable config + doctor + new workspace)

struct ProjectOverviewView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var project: ProjectStore
    let onNewWorkspace: () -> Void

    @StateObject private var draft: ConfigDraft
    @State private var showInspector = true

    init(project: ProjectStore, onNewWorkspace: @escaping () -> Void) {
        self.project = project
        self.onNewWorkspace = onNewWorkspace
        _draft = StateObject(wrappedValue: ConfigDraft(project.config))
    }

    var body: some View {
        ProjectDashboard(project: project, onNewWorkspace: onNewWorkspace)
            .navigationTitle(project.name)
            .navigationSubtitle(project.rootURL.path)
            .inspector(isPresented: $showInspector) {
                ConfigFormView(
                    draft: draft,
                    projectRoot: project.rootURL,
                    saveTitle: "Save changes",
                    onSave: { try app.saveConfig($0, to: project.rootURL) }
                )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onNewWorkspace) {
                        Label("New Workspace", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Configuration", systemImage: "sidebar.trailing")
                    }
                    .help("Toggle configuration")
                    .accessibilityLabel("Toggle configuration")
                }
            }
    }
}
