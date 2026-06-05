import SwiftUI
import AppKit
import SproutEngine

enum SidebarSelection: Hashable {
    case projectRoot(projectID: String)
    case workspace(projectID: String, id: UUID)
}

struct MainWindow: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: SidebarSelection?
    @State private var createForProject: ProjectStore?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $selection,
                onAddProject: { presentAddProjectPanel(app) },
                onNewProject: { app.presentingNewProject = true },
                onNewWorkspace: { createForProject = $0 }
            )
            .frame(minWidth: 240)
        } detail: {
            DetailContainer(
                selection: selection,
                onNewWorkspace: { createForProject = $0 })
        }
        .sheet(item: $createForProject) { project in
            CreateWorkspaceSheet(project: project)
        }
        .sheet(isPresented: $app.presentingNewProject) {
            CreateProjectSheet()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reconcile all projects")
            }
        }
        .onAppear { app.refreshAll() }
    }
}

/// Shared "Add Project" folder picker, used by both the File menu command and the
/// sidebar empty-state button.
@MainActor
func presentAddProjectPanel(_ app: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add Project"
    panel.message = "Choose a folder containing a .sprout.toml"
    if panel.runModal() == .OK, let url = panel.url {
        app.addProject(url)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var app: AppModel
    @Binding var selection: SidebarSelection?
    let onAddProject: () -> Void
    let onNewProject: () -> Void
    let onNewWorkspace: (ProjectStore) -> Void

    /// Projects whose worktree list is collapsed (expanded by default).
    @State private var collapsed: Set<String> = []

    var body: some View {
        List(selection: $selection) {
            if app.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "leaf")
                } description: {
                    Text("Create a new project or add a folder with a .sprout.toml.")
                } actions: {
                    Button("New Project", action: onNewProject)
                    Button("Add Project", action: onAddProject)
                }
            }
            ForEach(app.projects) { project in
                DisclosureGroup(isExpanded: expansion(for: project.id)) {
                    if project.workspaces.isEmpty {
                        Text("No worktrees")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(project.workspaces) { item in
                        NavigationLink(
                            value: SidebarSelection.workspace(projectID: project.id, id: item.id)
                        ) {
                            HStack {
                                StatusBadge(status: item.record.status, showText: false)
                                Text(item.record.branch)
                                Spacer()
                                Text(":\(item.record.port)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .opacity(item.orphaned ? 0.5 : 1)
                        }
                    }
                } label: {
                    HStack {
                        Button {
                            selection = .projectRoot(projectID: project.id)
                        } label: {
                            Label(project.name, systemImage: "folder")
                                .font(.headline)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            onNewWorkspace(project)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("New workspace in \(project.name)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { isExpanded in
                if isExpanded { collapsed.remove(id) } else { collapsed.insert(id) }
            })
    }
}

// MARK: - Detail routing

struct DetailContainer: View {
    @EnvironmentObject var app: AppModel
    let selection: SidebarSelection?
    let onNewWorkspace: (ProjectStore) -> Void

    var body: some View {
        switch selection {
        case let .workspace(projectID, id):
            if let project = app.projects.first(where: { $0.id == projectID }),
                let item = project.workspaces.first(where: { $0.id == id })
            {
                WorkspaceDetailView(project: project, item: item)
            } else {
                placeholder
            }
        case let .projectRoot(projectID):
            if let project = app.projects.first(where: { $0.id == projectID }) {
                ProjectOverviewView(project: project, onNewWorkspace: { onNewWorkspace(project) })
            } else {
                placeholder
            }
        case .none:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "Select a Workspace",
            systemImage: "sidebar.left",
            description: Text("Pick a project or workspace from the sidebar."))
    }
}
