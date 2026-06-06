import SwiftUI
import AppKit
import ServiceManagement
import SproutEngine

enum SidebarSelection: Hashable {
    case projectRoot(projectID: String)
    case workspace(projectID: String, id: UUID)
}

struct MainWindow: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: SidebarSelection?
    @State private var createForProject: ProjectStore?
    @State private var showingHelperSetup = false
    @State private var drawerVisible = false
    @AppStorage("shellDrawerHeight") private var drawerHeight: Double = 240

    /// The selected workspace as a (store, item) pair, or nil if the selection is not a
    /// workspace or no longer exists.
    private var selectedWorkspace: (ProjectStore, WorkspaceItem)? {
        guard case let .workspace(projectID, id) = selection,
            let project = app.projects.first(where: { $0.id == projectID }),
            let item = project.workspaces.first(where: { $0.id == id })
        else { return nil }
        return (project, item)
    }

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
                drawerVisible: $drawerVisible,
                drawerHeight: $drawerHeight,
                onNewWorkspace: { createForProject = $0 })
        }
        .sheet(item: $createForProject) { project in
            CreateWorkspaceSheet(project: project)
        }
        .sheet(isPresented: $app.presentingNewProject) {
            CreateProjectSheet()
        }
        .sheet(isPresented: $showingHelperSetup) {
            HelperSetupSheet()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reconcile all projects")
                .accessibilityLabel("Reconcile all projects")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    drawerVisible.toggle()
                } label: {
                    Image(systemName: "terminal")
                }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(selectedWorkspace == nil)
                .help("Toggle shell (⌘J)")
                .accessibilityLabel("Toggle shell")
            }
        }
        .onAppear {
            app.refreshAll()
            // Prompt to install/enable the loopback helper on first sight if it
            // isn't already enabled. Dismissible, so dev builds aren't blocked.
            app.helper.refresh()
            if app.helper.status != .enabled {
                showingHelperSetup = true
            }
        }
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
                                Image(systemName: "arrow.triangle.branch")
                                    .foregroundStyle(item.record.status.color)
                                    .accessibilityLabel("Status: \(item.record.status.label)")
                                Text(item.record.branch)
                                Spacer()
                                Text(":\(item.record.port)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .opacity(item.orphaned ? 0.5 : 1)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { project.revealInFinder(item) }
                            Button("Open in Editor") { project.openInEditor(item) }
                            Button("Open in Browser") { project.openInBrowser(item) }
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
                        .accessibilityLabel("New workspace in \(project.name)")
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
    @Binding var drawerVisible: Bool
    @Binding var drawerHeight: Double
    let onNewWorkspace: (ProjectStore) -> Void

    var body: some View {
        switch selection {
        case let .workspace(projectID, id):
            if let project = app.projects.first(where: { $0.id == projectID }),
                let item = project.workspaces.first(where: { $0.id == id })
            {
                WorkspaceDetailView(
                    project: project, item: item,
                    drawerVisible: $drawerVisible, drawerHeight: $drawerHeight)
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
