import Foundation

/// File-backed store. Serializes the whole record array on each write (atomic).
/// Single-process use (the CLI); a serial queue guards concurrent calls within the process.
public final class JSONStateStore: StateStore, @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "sprout.jsonstatestore")

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> [WorkspaceRecord] {
        try queue.sync { try readAll() }
    }

    public func upsert(_ record: WorkspaceRecord) throws {
        try queue.sync {
            var all = try readAll()
            if let i = all.firstIndex(where: { $0.id == record.id }) { all[i] = record }
            else { all.append(record) }
            try writeAll(all)
        }
    }

    public func remove(id: UUID) throws {
        try queue.sync {
            var all = try readAll()
            all.removeAll { $0.id == id }
            try writeAll(all)
        }
    }

    private func readAll() throws -> [WorkspaceRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode([WorkspaceRecord].self, from: data)
    }

    private func writeAll(_ records: [WorkspaceRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}
