import Foundation

/// One registered project: its repo root (the stable identity) plus the
/// `[project] name` used to locate its config under `~/.sprout/configs`.
public struct ProjectRef: Codable, Equatable, Sendable {
    public let path: String  // normalized project root
    public var name: String

    public init(path: String, name: String) {
        self.path = ProjectRegistry.normalize(path)
        self.name = name
    }
}

/// Persistent list of projects the app manages. Configs live in the home dir
/// (`~/.sprout/configs/<name>.toml`), not the repo, so they aren't shared — the
/// registry therefore records each project's name to find its config.
/// Pure value type; load/save take an explicit URL so it is testable without `~`.
public struct ProjectRegistry: Codable, Equatable, Sendable {
    public private(set) var projects: [ProjectRef]

    public init(projects: [ProjectRef] = []) {
        self.projects = projects
    }

    public var isEmpty: Bool { projects.isEmpty }

    public func contains(_ path: String) -> Bool {
        let norm = Self.normalize(path)
        return projects.contains { $0.path == norm }
    }

    public func name(forPath path: String) -> String? {
        let norm = Self.normalize(path)
        return projects.first { $0.path == norm }?.name
    }

    /// Register a project, or update its name if the path is already known.
    /// Returns true when a new entry was added.
    @discardableResult
    public mutating func add(path: String, name: String) -> Bool {
        let norm = Self.normalize(path)
        if let i = projects.firstIndex(where: { $0.path == norm }) {
            projects[i].name = name
            return false
        }
        projects.append(ProjectRef(path: norm, name: name))
        return true
    }

    public mutating func remove(_ path: String) {
        let norm = Self.normalize(path)
        projects.removeAll { $0.path == norm }
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: Codable (also decodes the legacy `projectPaths` format)

    private enum CodingKeys: String, CodingKey { case projects }
    private struct Legacy: Decodable { let projectPaths: [String] }

    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
            let refs = try? c.decode([ProjectRef].self, forKey: .projects)
        {
            self.projects = refs
        } else if let legacy = try? Legacy(from: decoder) {
            // Old registries stored bare paths with no name; such entries can't
            // locate a home config until re-added, but decoding must not crash.
            self.projects = legacy.projectPaths.map { ProjectRef(path: $0, name: "") }
        } else {
            self.projects = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projects, forKey: .projects)
    }

    public static func load(from url: URL) -> ProjectRegistry {
        guard let data = try? Data(contentsOf: url),
            let reg = try? JSONDecoder().decode(ProjectRegistry.self, from: data)
        else { return ProjectRegistry() }
        return reg
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
