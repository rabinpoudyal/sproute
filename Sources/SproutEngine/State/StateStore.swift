import Foundation

public enum WorkspaceStatus: String, Codable, Sendable {
    case creating, running, crashed, stopped, tearingDown
}

public enum ProcessStatus: String, Codable, Sendable { case running, stopped, crashed }

public struct ProcessState: Codable, Sendable, Equatable {
    public var name: String
    public var pid: Int32?
    public var status: ProcessStatus
    public init(name: String, pid: Int32?, status: ProcessStatus) {
        self.name = name; self.pid = pid; self.status = status
    }
}

public struct WorkspaceRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var branch: String
    public var base: String
    public var worktreePath: String
    public var port: Int
    public var dbName: String
    public var status: WorkspaceStatus
    public var processes: [ProcessState]
    public var createdAt: Date

    public init(
        id: UUID, branch: String, base: String, worktreePath: String,
        port: Int, dbName: String, status: WorkspaceStatus,
        createdAt: Date, processes: [ProcessState] = []
    ) {
        self.id = id; self.branch = branch; self.base = base
        self.worktreePath = worktreePath; self.port = port; self.dbName = dbName
        self.status = status; self.createdAt = createdAt; self.processes = processes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        branch = try c.decode(String.self, forKey: .branch)
        base = try c.decode(String.self, forKey: .base)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        port = try c.decode(Int.self, forKey: .port)
        dbName = try c.decode(String.self, forKey: .dbName)
        status = try c.decode(WorkspaceStatus.self, forKey: .status)
        processes = try c.decodeIfPresent([ProcessState].self, forKey: .processes) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

public protocol StateStore: Sendable {
    func load() throws -> [WorkspaceRecord]
    func upsert(_ record: WorkspaceRecord) throws
    func remove(id: UUID) throws
}

/// "All-running" semantics: running only if every process runs; crashed if any
/// crashed; otherwise stopped. `creating`/`tearingDown` are set explicitly elsewhere
/// and never derived from processes.
public func aggregateStatus(_ processes: [ProcessState]) -> WorkspaceStatus {
    if processes.isEmpty { return .stopped }
    if processes.contains(where: { $0.status == .crashed }) { return .crashed }
    if processes.allSatisfy({ $0.status == .running }) { return .running }
    return .stopped
}
