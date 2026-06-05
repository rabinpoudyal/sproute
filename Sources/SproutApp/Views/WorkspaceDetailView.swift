import SwiftUI
import AppKit
import SproutEngine

struct WorkspaceDetailView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var project: ProjectStore
    let item: WorkspaceItem
    @Binding var drawerVisible: Bool
    @Binding var drawerHeight: Double

    @State private var busy = false
    @State private var confirmDone = false
    @State private var confirmDiscard = false
    @State private var dirtyWarning = false
    @State private var selection: DetailSelection?
    @State private var showInspector = true

    /// What the main pane is showing: a process's logs, or a live console session.
    enum DetailSelection: Hashable {
        case process(String)
        case console(UUID)
    }

    private var rec: WorkspaceRecord { item.record }
    private var processNames: [String] { project.config.run.processes.map(\.name) }
    private var consoles: [ConsoleSessionItem] {
        project.consoleSessions.filter { $0.branch == rec.branch }
    }
    private var consoleConfigNames: [String] { project.config.run.consoles.map(\.name) }

    /// Default to the first process, else the first console, else nil.
    private var current: DetailSelection? {
        if let selection { return selection }
        if let first = processNames.first { return .process(first) }
        if let firstConsole = consoles.first { return .console(firstConsole.id) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let current {
                selectorBar(current)
                Divider()
                content(current)
            } else {
                ContentUnavailableView(
                    "Nothing to show", systemImage: "bolt.slash",
                    description: Text("This workspace defines no run processes or consoles."))
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

    private func selectorBar(_ current: DetailSelection) -> some View {
        HStack(spacing: 12) {
            Picker(
                "View",
                selection: Binding(
                    get: { current },
                    set: { selection = $0 })
            ) {
                ForEach(processNames, id: \.self) { proc in
                    Label {
                        Text(proc)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(dotColor(proc))
                    }
                    .tag(DetailSelection.process(proc))
                }
                ForEach(consoles) { session in
                    Label {
                        Text(session.name)
                    } icon: {
                        Image(systemName: "terminal")
                    }
                    .tag(DetailSelection.console(session.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()

            if !consoleConfigNames.isEmpty {
                Menu {
                    ForEach(consoleConfigNames, id: \.self) { name in
                        Button(name) {
                            run {
                                await project.startConsole(item, name: name)
                                if let new = project.consoleSessions
                                    .last(where: { $0.branch == rec.branch && $0.name == name })
                                {
                                    selection = .console(new.id)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Console", systemImage: "terminal")
                }
                .help("Start an interactive console")
            }

            // Per-selection controls.
            switch current {
            case .process(let name):
                Button {
                    run { await project.startProcess(item, name: name) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                Button {
                    run { await project.stopProcess(item, name: name) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                Button {
                    run { await project.restartProcess(item, name: name) }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
            case .console(let id):
                Button {
                    run { await project.stopConsole(id: id) }
                    selection = nil
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                Button {
                    openWindow(value: ConsoleTarget(projectID: project.id, sessionID: id))
                } label: {
                    Label("Pop Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal).padding(.vertical, 6)
    }

    @ViewBuilder
    private func content(_ current: DetailSelection) -> some View {
        switch current {
        case .process(let name):
            LogConsoleView(
                buffer: project.logBuffer(branch: rec.branch, process: name),
                onPopOut: {
                    openWindow(
                        value: LogTarget(
                            projectID: project.id, branch: rec.branch, process: name))
                })
        case .console(let id):
            if let controller = project.consoleController(id: id) {
                ConsoleView(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Console ended", systemImage: "terminal")
            }
        }
    }

    private func dotColor(_ name: String) -> Color {
        switch rec.processes.first(where: { $0.name == name })?.status {
        case .running: return .green
        case .crashed: return .red
        default: return .secondary
        }
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
            Button {
                run { await project.startAll(item) }
            } label: {
                Label("Start all", systemImage: "play.fill")
            }
            .disabled(item.orphaned)
            .help("Start all processes")
            Button {
                run { await project.stopAll(item) }
            } label: {
                Label("Stop all", systemImage: "stop.fill")
            }
            .help("Stop all processes")
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
        if let url = URL(string: "http://localhost:\(rec.port)") {
            NSWorkspace.shared.open(url)
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
