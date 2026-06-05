import Combine
import Foundation
import SproutEngine

enum AggregateStatus { case idle, running, error }

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

    init() {
        registry = ProjectRegistry.load(from: SproutPaths.registryFile)
        loadProjects()
    }

    func loadProjects() {
        var stores: [ProjectStore] = []
        for path in registry.projectPaths {
            let root = URL(fileURLWithPath: path)
            let configURL = root.appendingPathComponent(".sprout.toml")
            guard let config = try? TOMLConfigLoader.load(path: configURL) else { continue }
            stores.append(ProjectStore(rootURL: root, config: config))
        }
        projects = stores
        storeSubscriptions = stores.map { store in
            store.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        for p in projects { p.refresh() }
    }

    func addProject(_ url: URL) {
        let configURL = url.appendingPathComponent(".sprout.toml")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            registryError = "No .sprout.toml found in \(url.lastPathComponent)."
            return
        }
        registry.add(url.path)
        do { try registry.save(to: SproutPaths.registryFile) } catch { registryError = "\(error)" }
        loadProjects()
    }

    func removeProject(_ store: ProjectStore) {
        registry.remove(store.rootURL.path)
        try? registry.save(to: SproutPaths.registryFile)
        loadProjects()
    }

    /// Write an edited config back to a project's `.sprout.toml`, then reload so the
    /// engine picks up the new settings. Throws on a write failure (shown by the form).
    func saveConfig(_ config: Config, to root: URL) throws {
        let url = root.appendingPathComponent(".sprout.toml")
        try TOMLConfigWriter.serialize(config).write(to: url, atomically: true, encoding: .utf8)
        loadProjects()
    }

    /// Author a brand-new project: write its `.sprout.toml`, register the folder,
    /// then load it. Throws on a write failure.
    func createProject(at root: URL, config: Config) throws {
        let url = root.appendingPathComponent(".sprout.toml")
        try TOMLConfigWriter.serialize(config).write(to: url, atomically: true, encoding: .utf8)
        registry.add(root.path)
        try registry.save(to: SproutPaths.registryFile)
        loadProjects()
    }

    func refreshAll() {
        for p in projects { p.refresh() }
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
