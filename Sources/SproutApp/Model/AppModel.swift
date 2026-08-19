import Combine
import Foundation
import SproutEngine

enum AggregateStatus { case idle, running, error }

/// One agent plus the project it belongs to, for the app-wide Agent World view.
struct WorldAgent: Identifiable {
    let projectID: String
    let projectName: String
    let agent: AgentRuntime
    var id: UUID { agent.id }
}

/// Top-level app state: the set of registered projects plus add/remove and
/// aggregate status for the menu-bar icon.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [ProjectStore] = []
    @Published var registryError: String?
    /// Set by the File menu's "New Project" command; the main window observes this
    /// to present the create-project sheet (menu commands can't touch window state).
    @Published var presentingNewProject = false

    private var registry: ProjectRegistry
    /// Re-publish each child store's changes as our own. Without this, a `@Published`
    /// change inside a single ProjectStore (e.g. `workspaces` after teardown) never
    /// reaches views that observe AppModel — the sidebar and detail router are stale.
    private var storeSubscriptions: [AnyCancellable] = []

    let helper = HelperManager()

    /// Per-workspace loopback IPs (127.0.10.N + a privileged helper) are hard
    /// disabled: they caused more setup friction than the concurrent-same-port
    /// benefit was worth, especially now the product is moving toward agents.
    /// Everything binds 127.0.0.1. The loopback/helper code stays in the tree
    /// (dormant) so this is a one-line revert — flip back to the UserDefaults read.
    var loopbackEnabled: Bool { false }

    init() {
        registry = ProjectRegistry.load(from: SproutPaths.registryFile)
        loadProjects()
        helper.refresh()
        Task { await sweepStaleLoopbackAliases() }
    }

    /// One-shot crash-recovery sweep at launch: ask the helper what it still
    /// manages and drop aliases no live workspace backs. Runs through a dedicated
    /// coordinator (the per-project ones are for refcounting). No-op when the
    /// loopback feature is disabled.
    private func sweepStaleLoopbackAliases() async {
        guard loopbackEnabled else { return }
        let live = Set(projects.flatMap { $0.runningBindIPs() })
        let coordinator = LoopbackCoordinator(provisioner: XPCProvisioner())
        await coordinator.sweep(live: live)
    }

    func loadProjects() {
        var stores: [ProjectStore] = []
        for ref in registry.projects {
            // Config lives in the home dir, keyed by name — never read from the repo.
            let configURL = SproutPaths.configFile(projectName: ref.name)
            guard !ref.name.isEmpty,
                let config = try? TOMLConfigLoader.load(path: configURL)
            else { continue }
            stores.append(
                ProjectStore(
                    rootURL: URL(fileURLWithPath: ref.path), config: config,
                    loopbackEnabled: loopbackEnabled))
        }
        projects = stores
        storeSubscriptions = stores.map { store in
            store.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        for p in projects { p.refresh() }
    }

    /// Import an existing project: read its repo `.sprout.toml` once and copy it
    /// into the home config dir, then register {path, name}. This is the only path
    /// that touches a repo config — steady-state loading is home-only.
    func addProject(_ url: URL) {
        let configURL = url.appendingPathComponent(".sprout.toml")
        guard let config = try? TOMLConfigLoader.load(path: configURL) else {
            registryError =
                "No .sprout.toml in \(url.lastPathComponent). Use New Project to author one."
            return
        }
        do {
            try writeHomeConfig(config)
            registry.add(path: url.path, name: config.project.name)
            try registry.save(to: SproutPaths.registryFile)
            loadProjects()
        } catch {
            registryError = "\(error)"
        }
    }

    func removeProject(_ store: ProjectStore) {
        registry.remove(store.rootURL.path)
        try? registry.save(to: SproutPaths.registryFile)
        loadProjects()
    }

    /// Write an edited config back to the home config dir, then reload. Also
    /// updates the registry name in case the project was renamed. Throws on failure.
    func saveConfig(_ config: Config, to root: URL) throws {
        try writeHomeConfig(config)
        registry.add(path: root.path, name: config.project.name)
        try registry.save(to: SproutPaths.registryFile)
        loadProjects()
    }

    /// Author a brand-new project: write its config to the home dir, register the
    /// folder + name, then load it. Throws on a write failure.
    func createProject(at root: URL, config: Config) throws {
        try writeHomeConfig(config)
        registry.add(path: root.path, name: config.project.name)
        try registry.save(to: SproutPaths.registryFile)
        loadProjects()
    }

    /// Serialize a config to `~/.sprout/configs/<name>.toml`, creating the dir.
    private func writeHomeConfig(_ config: Config) throws {
        let url = SproutPaths.configFile(projectName: config.project.name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TOMLConfigWriter.serialize(config).write(to: url, atomically: true, encoding: .utf8)
    }

    func refreshAll() {
        for p in projects { p.refresh() }
    }

    // MARK: - Agents (app-wide)

    func project(id: String) -> ProjectStore? {
        projects.first { $0.id == id }
    }

    /// Every launched agent across all projects, for the Agent World view.
    func allAgents() -> [WorldAgent] {
        projects.flatMap { store in
            store.agents.map {
                WorldAgent(projectID: store.id, projectName: store.name, agent: $0)
            }
        }
    }

    func sendAgentInput(projectID: String, agentID: UUID, _ text: String) {
        project(id: projectID)?.sendAgentInput(id: agentID, text)
    }

    func stopAgent(projectID: String, agentID: UUID) async {
        await project(id: projectID)?.stopAgent(id: agentID)
    }

    var aggregateStatus: AggregateStatus {
        let all = projects.flatMap { $0.workspaces }
        if all.contains(where: { $0.record.status == .crashed }) { return .error }
        if all.contains(where: { $0.record.status == .running }) { return .running }
        return .idle
    }

    var runningCount: Int {
        projects.flatMap { $0.workspaces }.filter { $0.record.status == .running }.count
    }
}
