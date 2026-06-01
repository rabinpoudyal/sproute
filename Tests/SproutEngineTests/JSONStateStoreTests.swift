import Testing
import Foundation
@testable import SproutEngine

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sprout-\(UUID().uuidString).json")
}

private func sampleRecord(branch: String = "feature/login") -> WorkspaceRecord {
    WorkspaceRecord(
        id: UUID(), branch: branch, base: "main",
        worktreePath: "/wt/\(branch)", port: 4001, dbName: "shop_x",
        status: .running, serverPID: 123, createdAt: Date(timeIntervalSince1970: 0)
    )
}

@Test func loadReturnsEmptyWhenFileMissing() throws {
    let store = JSONStateStore(fileURL: tempFile())
    #expect(try store.load().isEmpty)
}

@Test func upsertThenLoadRoundTrips() throws {
    let store = JSONStateStore(fileURL: tempFile())
    let r = sampleRecord()
    try store.upsert(r)
    let loaded = try store.load()
    #expect(loaded == [r])
}

@Test func upsertReplacesSameID() throws {
    let store = JSONStateStore(fileURL: tempFile())
    var r = sampleRecord()
    try store.upsert(r)
    r.status = .stopped
    try store.upsert(r)
    let loaded = try store.load()
    #expect(loaded.count == 1)
    #expect(loaded.first?.status == .stopped)
}

@Test func removeDeletesByID() throws {
    let store = JSONStateStore(fileURL: tempFile())
    let r = sampleRecord()
    try store.upsert(r)
    try store.remove(id: r.id)
    #expect(try store.load().isEmpty)
}
