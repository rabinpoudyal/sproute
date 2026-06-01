import Foundation
import SproutEngine

enum AggregateStatus { case idle, running, error }

/// Top-level app state: the set of registered projects plus add/remove and
/// aggregate status for the menu-bar icon.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [ProjectStore] = []
    @Published var registryError: String?

    private var registry: ProjectRegistry

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
