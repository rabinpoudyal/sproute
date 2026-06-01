import Testing
import Foundation
@testable import SproutEngine

private struct StubProber: PortProber {
    let busy: Set<Int>
    func isFree(_ port: Int) -> Bool { !busy.contains(port) }
}

private func record(port: Int) -> WorkspaceRecord {
    WorkspaceRecord(id: UUID(), branch: "b", base: "main", worktreePath: "/x",
                    port: port, dbName: "d", status: .running,
                    serverPID: nil, createdAt: Date())
}

@Test func allocatesFirstFreePort() throws {
    let store = FakeStateStore()
    let alloc = PortAllocator(config: PortConfig(lower: 4000, upper: 4010),
                              store: store, prober: StubProber(busy: []))
    #expect(try alloc.allocate() == 4000)
}

@Test func skipsPortsHeldByRecords() throws {
    let store = FakeStateStore()
    store.records = [record(port: 4000), record(port: 4001)]
    let alloc = PortAllocator(config: PortConfig(lower: 4000, upper: 4010),
                              store: store, prober: StubProber(busy: []))
    #expect(try alloc.allocate() == 4002)
}

@Test func skipsPortsProberSaysBusy() throws {
    let store = FakeStateStore()
    let alloc = PortAllocator(config: PortConfig(lower: 4000, upper: 4010),
                              store: store, prober: StubProber(busy: [4000, 4001]))
    #expect(try alloc.allocate() == 4002)
}

@Test func throwsWhenRangeExhausted() {
    let store = FakeStateStore()
    store.records = [record(port: 4000)]
    let alloc = PortAllocator(config: PortConfig(lower: 4000, upper: 4000),
                              store: store, prober: StubProber(busy: []))
    #expect(throws: PortError.noFreePort) { _ = try alloc.allocate() }
}
