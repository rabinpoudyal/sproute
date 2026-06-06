import SwiftUI
import AppKit
import SproutEngine

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
    @State private var path: [String] = []
    @State private var showInspector = true

    private var rec: WorkspaceRecord { item.record }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationStack(path: $path) {
                ProcessListView(project: project, item: item, busy: $busy)
                    .navigationTitle(project.name)
                    .navigationSubtitle(rec.branch)
                    .navigationDestination(for: String.self) { name in
                        ProcessDetailView(
                            project: project, item: item, name: name, busy: $busy)
                    }
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
        .inspector(isPresented: $showInspector) {
            inspector
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
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
    }

    // MARK: inspector

    private var inspector: some View {
        Form {
            Section {
                LabeledContent("Status") { StatusBadge(status: rec.status) }
                if item.orphaned {
                    Label("worktree missing", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                portRows
                field("Database", rec.dbName)
                field("Branch", rec.branch)
                field("Worktree", rec.worktreePath)
            }
            Section("Open") {
                Button {
                    reveal()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button {
                    openInEditor()
                } label: {
                    Label("Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button {
                    openInBrowser()
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func field(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.callout.monospaced())
        }
    }

    @ViewBuilder private var portRows: some View {
        let plan = portPlan(project.config.run.processes)
        if plan.isEmpty {
            field("Port", "none")
        } else {
            ForEach(plan.sorted { $0.value < $1.value }, id: \.key) { name, port in
                field(name, ":\(port)")
            }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Reveal in Finder") { reveal() }
                Button("Open in Editor") { openInEditor() }
                Button("Open in Browser") { openInBrowser() }
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

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.worktreePath)])
    }

    private func openInEditor() {
        let url = URL(fileURLWithPath: rec.worktreePath)
        // Plain `open` on a directory hands it to the default folder handler (Finder).
        // Open it in VS Code when present, else fall back to the default handler.
        if let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.microsoft.VSCode")
        {
            NSWorkspace.shared.open(
                [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openInBrowser() {
        if let url = project.browserURL(rec) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Process list + detail

/// One row in the workspace process list: status dot, name, optional port badge,
/// and inline Start/Stop. The row body is a NavigationLink (pushes detail); the
/// buttons use `.borderless` so a tap hits the button, not the link.
private struct ProcessRow: View {
    let proc: ProcessConfig
    let status: ProcessStatus?
    let orphaned: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(dotColor)
            Text(proc.name)
            if let port = proc.port {
                Text(":\(port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onStart) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Start")
            .disabled(orphaned || status == .running)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop")
            .disabled(status != .running)
        }
        .padding(.vertical, 2)
    }

    private var dotColor: Color {
        switch status {
        case .running: return .green
        case .crashed: return .red
        default: return .secondary
        }
    }
}

/// Stack root: the list of a workspace's run processes.
private struct ProcessListView: View {
    @ObservedObject var project: ProjectStore
    let item: WorkspaceItem
    @Binding var busy: Bool

    private var rec: WorkspaceRecord { item.record }
    private var processes: [ProcessConfig] { project.config.run.processes }

    var body: some View {
        Group {
            if processes.isEmpty {
                ContentUnavailableView(
                    "No processes", systemImage: "bolt.slash",
                    description: Text("This workspace defines no run processes."))
            } else {
                List {
                    ForEach(processes, id: \.name) { proc in
                        NavigationLink(value: proc.name) {
                            ProcessRow(
                                proc: proc,
                                status: status(of: proc.name),
                                orphaned: item.orphaned,
                                onStart: {
                                    run { await project.startProcess(item, name: proc.name) }
                                },
                                onStop: {
                                    run { await project.stopProcess(item, name: proc.name) }
                                })
                        }
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
        LogConsoleView(
            buffer: project.logBuffer(branch: rec.branch, process: name),
            onPopOut: {
                openWindow(
                    value: LogTarget(projectID: project.id, branch: rec.branch, process: name))
            }
        )
        .navigationTitle(name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    run { await project.startProcess(item, name: name) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(item.orphaned || status == .running)
                Button {
                    run { await project.stopProcess(item, name: name) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(status != .running)
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

    init(project: ProjectStore, onNewWorkspace: @escaping () -> Void) {
        self.project = project
        self.onNewWorkspace = onNewWorkspace
        _draft = StateObject(wrappedValue: ConfigDraft(project.config))
    }

    var body: some View {
        ConfigFormView(
            draft: draft,
            projectRoot: project.rootURL,
            saveTitle: "Save changes",
            onSave: { try app.saveConfig($0, to: project.rootURL) },
            extra: { doctorSection }
        )
        .navigationTitle(project.name)
        .navigationSubtitle(project.rootURL.path)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewWorkspace) {
                    Label("New Workspace", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder private var doctorSection: some View {
        Section("Doctor") {
            if project.doctor.isEmpty {
                Text("Not run yet.").foregroundStyle(.secondary)
            }
            ForEach(project.doctor, id: \.tool) { check in
                HStack {
                    Image(
                        systemName: check.found
                            ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(check.found ? Color.green : Color.red)
                    Text(check.tool).bold()
                    Text(check.path ?? "not found")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Button("Run Doctor") { Task { await project.runDoctor() } }
        }
    }
}
