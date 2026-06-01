import SwiftUI
import AppKit
import SproutEngine

struct WorkspaceDetailView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var project: ProjectStore
    let item: WorkspaceItem

    @State private var busy = false
    @State private var confirmDone = false
    @State private var confirmDiscard = false
    @State private var dirtyWarning = false
    @State private var selectedProcess: String?

    private var rec: WorkspaceRecord { item.record }
    private var processNames: [String] { project.config.run.processes.map(\.name) }
    private var current: String? { selectedProcess ?? processNames.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let current {
                processBar(current)
                Divider()
                LogConsoleView(
                    buffer: project.logBuffer(branch: rec.branch, process: current),
                    onPopOut: {
                        openWindow(
                            value: LogTarget(
                                projectID: project.id, branch: rec.branch, process: current))
                    })
            } else {
                ContentUnavailableView(
                    "No processes", systemImage: "bolt.slash",
                    description: Text("This workspace defines no run processes."))
            }
        }
        .navigationTitle(rec.branch)
        .navigationSubtitle(rec.worktreePath)
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

    // MARK: header

    private var header: some View {
        HStack(spacing: 16) {
            StatusBadge(status: rec.status)
            if item.orphaned {
                Label("worktree missing", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            field("Port", ":\(rec.port)")
            field("Database", rec.dbName)
            Spacer()
        }
        .padding()
    }

    private func processBar(_ name: String) -> some View {
        HStack(spacing: 12) {
            Picker(
                "Process",
                selection: Binding(
                    get: { current ?? name },
                    set: { selectedProcess = $0 })
            ) {
                ForEach(processNames, id: \.self) { proc in
                    Label {
                        Text(proc)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(dotColor(proc))
                    }
                    .tag(proc)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer()
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
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal).padding(.vertical, 6)
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

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if busy { ProgressView().controlSize(.small) }
            Button {
                run { await project.startAll(item) }
            } label: {
                Label("Start all", systemImage: "play.fill")
            }
            .disabled(item.orphaned)
            Button {
                run { await project.stopAll(item) }
            } label: {
                Label("Stop all", systemImage: "stop.fill")
            }
            Menu {
                Button("Reveal in Finder") { reveal() }
                Button("Open in Editor") { openInEditor() }
                Button("Open in Browser") { openInBrowser() }
                Divider()
                Button("Push") { run { await project.push(item) } }
                Button("Done (push & tear down)") { confirmDone = true }
                Button("Discard…", role: .destructive) { confirmDiscard = true }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
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
