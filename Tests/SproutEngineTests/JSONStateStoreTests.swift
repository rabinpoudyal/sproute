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
        status: .running, createdAt: Date(timeIntervalSince1970: 0),
        processes: [ProcessState(name: "server", pid: 123, status: .running)])
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

@Test func recordDecodesWithoutBindIPDefaultsToLoopback() throws {
    let json = """
        {"id":"550e8400-e29b-41d4-a716-446655440000","branch":"main","base":"main",\
        "worktreePath":"/wt/main","port":3000,"dbName":"shop_main",\
        "status":"stopped","createdAt":"2026-06-06T00:00:00Z","processes":[]}
        """
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let rec = try dec.decode(WorkspaceRecord.self, from: Data(json.utf8))
    #expect(rec.bindIP == "127.0.0.1")
}

@Test func recordRoundTripsBindIP() throws {
    let rec = WorkspaceRecord(
        id: UUID(), branch: "main", base: "main", worktreePath: "/wt/main",
        port: 3000, dbName: "shop_main", status: .stopped,
        createdAt: Date(timeIntervalSince1970: 0), bindIP: "127.0.10.5")
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let back = try dec.decode(WorkspaceRecord.self, from: enc.encode(rec))
    #expect(back.bindIP == "127.0.10.5")
}
