import Testing

@testable import SproutEngine

@Suite struct LoopbackReaperTests {
    @Test func returnsManagedIPsWithNoLiveAllocation() {
        let stale = staleManagedIPs(
            managed: ["127.0.10.1", "127.0.10.2", "127.0.10.3"],
            live: ["127.0.10.2"])
        #expect(stale == ["127.0.10.1", "127.0.10.3"])
    }

    @Test func emptyWhenAllManagedAreLive() {
        let stale = staleManagedIPs(
            managed: ["127.0.10.1"], live: ["127.0.10.1"])
        #expect(stale.isEmpty)
    }

    @Test func dedupesAndPreservesOrder() {
        let stale = staleManagedIPs(
            managed: ["127.0.10.5", "127.0.10.5", "127.0.10.4"],
            live: [])
        #expect(stale == ["127.0.10.5", "127.0.10.4"])
    }
}
