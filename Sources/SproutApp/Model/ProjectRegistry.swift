import Foundation

/// Persistent list of project roots the app manages. Each root must contain a `.sprout.toml`.
/// Pure value type; load/save take an explicit URL so it is testable without touching `~`.
public struct ProjectRegistry: Codable, Equatable, Sendable {
    public private(set) var projectPaths: [String]

    public init(projectPaths: [String] = []) {
        self.projectPaths = projectPaths.map(Self.normalize)
    }

    public var isEmpty: Bool { projectPaths.isEmpty }

    public func contains(_ path: String) -> Bool {
        projectPaths.contains(Self.normalize(path))
    }

    @discardableResult
    public mutating func add(_ path: String) -> Bool {
        let norm = Self.normalize(path)
        guard !projectPaths.contains(norm) else { return false }
        projectPaths.append(norm)
        return true
    }

    public mutating func remove(_ path: String) {
        let norm = Self.normalize(path)
        projectPaths.removeAll { $0 == norm }
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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
