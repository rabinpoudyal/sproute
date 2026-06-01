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

    private var rec: WorkspaceRecord { item.record }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            serverBar
            Divider()
            LogConsoleView(
                buffer: project.logBuffer(for: rec.branch),
                onPopOut: {
                    openWindow(value: LogTarget(projectID: project.id, branch: rec.branch))
                })
        }
        .navigationTitle(rec.branch)
        .toolbar { lifecycleMenu }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(rec.branch).font(.title2.bold())
                StatusBadge(status: rec.status)
                if item.orphaned {
                    Label("worktree missing", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                field("Port", ":\(rec.port)")
                field("Database", rec.dbName)
                field("PID", rec.serverPID.map(String.init) ?? "—")
            }
            HStack(spacing: 8) {
                Text(rec.worktreePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Reveal") { reveal() }.buttonStyle(.link).font(.caption)
                Button("Editor") { openInEditor() }.buttonStyle(.link).font(.caption)
                Button("Browser") { openInBrowser() }.buttonStyle(.link).font(.caption)
            }
        }
        .padding()
    }

    private func field(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.callout.monospaced())
        }
    }

    // MARK: server controls

    private var serverBar: some View {
        HStack(spacing: 12) {
            if rec.status == .running {
                Button {
                    run { await project.stopServer(item) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                Button {
                    run { await project.startOrRestartServer(item) }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
            } else {
                Button {
                    run { await project.startOrRestartServer(item) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(item.orphaned)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var lifecycleMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Push") { run { await project.push(item) } }
                Divider()
                Button("Done (push & tear down)") { confirmDone = true }
                Button("Discard…", role: .destructive) { confirmDiscard = true }
            } label: {
                Image(systemName: "ellipsis.circle")
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
        NSWorkspace.shared.open(url)
    }

    private func openInBrowser() {
        if let url = URL(string: "http://localhost:\(rec.port)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Project overview (doctor + config + new workspace)

struct ProjectOverviewView: View {
    @ObservedObject var project: ProjectStore
    let onNewWorkspace: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(project.name).font(.title.bold())
                    Spacer()
                    Button(action: onNewWorkspace) {
                        Label("New Workspace", systemImage: "plus")
                    }
                }
                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 6) {
                        row("Root", project.rootURL.path)
                        row("Worktrees", project.config.worktree.baseDir)
                        row(
                            "Port range",
                            "\(project.config.port.lower)–\(project.config.port.upper)")
                        row("Server", project.config.run.serverCommand)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                GroupBox("Doctor") {
                    VStack(alignment: .leading, spacing: 6) {
                        if project.doctor.isEmpty {
                            Text("Not run yet.").foregroundStyle(.secondary)
                        }
                        ForEach(project.doctor, id: \.tool) { check in
                            HStack {
                                Image(
                                    systemName: check.found
                                        ? "checkmark.circle.fill" : "xmark.circle.fill"
                                )
                                .foregroundStyle(check.found ? .green : .red)
                                Text(check.tool).bold()
                                Text(check.path ?? "not found")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        Button("Run Doctor") { Task { await project.runDoctor() } }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding()
        }
        .navigationTitle(project.name)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
            Text(v).font(.callout.monospaced()).textSelection(.enabled)
        }
    }
}
