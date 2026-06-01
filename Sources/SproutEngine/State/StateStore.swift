import Foundation

public enum WorkspaceStatus: String, Codable, Sendable {
    case creating, running, crashed, stopped, tearingDown
}

public struct WorkspaceRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var branch: String
    public var base: String
    public var worktreePath: String
    public var port: Int
    public var dbName: String
    public var status: WorkspaceStatus
    public var serverPID: Int32?
    public var createdAt: Date

    public init(
        id: UUID, branch: String, base: String, worktreePath: String,
        port: Int, dbName: String, status: WorkspaceStatus,
        serverPID: Int32?, createdAt: Date
    ) {
        self.id = id; self.branch = branch; self.base = base
        self.worktreePath = worktreePath; self.port = port; self.dbName = dbName
        self.status = status; self.serverPID = serverPID; self.createdAt = createdAt
    }
}

public protocol StateStore: Sendable {
    func load() throws -> [WorkspaceRecord]
    func upsert(_ record: WorkspaceRecord) throws
    func remove(id: UUID) throws
}
