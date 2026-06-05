import Foundation

public enum LoopbackError: Error, Equatable {
    case exhausted
    case notAllocated(branch: String)
    case persistFailed(String)
}

public struct LoopbackAllocation: Codable, Sendable, Equatable {
    public var project: String
    public var branch: String
    public var ip: String

    public init(project: String, branch: String, ip: String) {
        self.project = project
        self.branch = branch
        self.ip = ip
    }
}

/// Global, persisted, sequential allocator: hands out 127.0.10.N across all
/// projects/branches, reusing freed slots. Serializes its whole table on each
/// write. Backed by its own JSON file (the `FileSystem` protocol has no read).
public actor IPAllocator {
    private static let prefix = "127.0.10."
    private static let lower = 1
    private static let upper = 254  // .255 reserved (subnet broadcast); .0 is the network address

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func allocate(project: String, branch: String) throws -> String {
        var table = try readAll()
        if let existing = table.first(where: {
            $0.project == project && $0.branch == branch
        }) {
            return existing.ip
        }
        let used = Set(table.compactMap { Self.octet($0.ip) })
        guard
            let free = (Self.lower...Self.upper)
                .first(where: { !used.contains($0) })
        else {
            throw LoopbackError.exhausted
        }
        let ip = "\(Self.prefix)\(free)"
        table.append(
            LoopbackAllocation(
                project: project, branch: branch, ip: ip
            ))
        try writeAll(table)
        return ip
    }

    // No-op when the entry is absent — teardown must be idempotent; double-release is harmless.
    public func release(project: String, branch: String) throws {
        var table = try readAll()
        table.removeAll { $0.project == project && $0.branch == branch }
        try writeAll(table)
    }

    public func ip(project: String, branch: String) -> String? {
        ((try? readAll()) ?? []).first(where: {
            $0.project == project && $0.branch == branch
        })?.ip
    }

    private static func octet(_ ip: String) -> Int? {
        guard ip.hasPrefix(prefix) else { return nil }
        return Int(ip.dropFirst(prefix.count))
    }

    private func readAll() throws -> [LoopbackAllocation] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL), !data.isEmpty
        else {
            return []
        }
        do {
            return try JSONDecoder().decode([LoopbackAllocation].self, from: data)
        } catch {
            throw LoopbackError.persistFailed(String(describing: error))
        }
    }

    private func writeAll(_ table: [LoopbackAllocation]) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(table).write(to: fileURL, options: .atomic)
        } catch {
            throw LoopbackError.persistFailed(String(describing: error))
        }
    }
}
