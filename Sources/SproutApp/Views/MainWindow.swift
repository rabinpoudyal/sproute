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
            SidebarView(selection: $selection,
                        onAddProject: addProject,
                        onNewWorkspace: { createForProject = $0 })
                .frame(minWidth: 240)
        } detail: {
            DetailContainer(selection: selection,
                            onNewWorkspace: { createForProject = $0 })
        }
        .sheet(item: $createForProject) { project in
            CreateWorkspaceSheet(project: project)
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

    private func addProject() {
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
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var app: AppModel
    @Binding var selection: SidebarSelection?
    let onAddProject: () -> Void
    let onNewWorkspace: (ProjectStore) -> Void

    var body: some View {
        List(selection: $selection) {
            if app.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "leaf")
                } description: {
                    Text("Add a folder with a .sprout.toml to get started.")
                } actions: {
                    Button("Add Project", action: onAddProject)
                }
            }
            ForEach(app.projects) { project in
                Section {
                    NavigationLink(value: SidebarSelection.projectRoot(projectID: project.id)) {
                        Label(project.name, systemImage: "folder")
                    }
                    ForEach(project.workspaces) { item in
                        NavigationLink(value: SidebarSelection.workspace(projectID: project.id, id: item.id)) {
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
                } header: {
                    HStack {
                        Text(project.name)
                        Spacer()
                        Button { onNewWorkspace(project) } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("New workspace in \(project.name)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !app.projects.isEmpty {
                Button(action: onAddProject) {
                    Label("Add Project", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        }
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
               let item = project.workspaces.first(where: { $0.id == id }) {
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
        ContentUnavailableView("Select a Workspace",
                               systemImage: "sidebar.left",
                               description: Text("Pick a project or workspace from the sidebar."))
    }
}
