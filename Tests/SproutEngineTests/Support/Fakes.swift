import Foundation
@testable import SproutEngine

final class FakeStateStore: StateStore, @unchecked Sendable {
    var records: [WorkspaceRecord] = []
    func load() throws -> [WorkspaceRecord] { records }
    func upsert(_ record: WorkspaceRecord) throws {
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record }
        else { records.append(record) }
    }
    func remove(id: UUID) throws { records.removeAll { $0.id == id } }
}
