import Testing
import Foundation
@testable import SproutEngine

private let hosts = ["web.shop.localhost", "vite.shop.localhost"]

@Test func firstActivateProvisionsOnce() async throws {
    let fake = FakeLoopbackProvisioner()
    let c = LoopbackCoordinator(provisioner: fake)
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // 2nd process
    #expect(
        fake.calls == [.init(ip: "127.0.10.1", hosts: hosts, active: true)]
    )
}

@Test func lastDeactivateReleasesOnce() async throws {
    let fake = FakeLoopbackProvisioner()
    let c = LoopbackCoordinator(provisioner: fake)
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // count 1
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // count 2
    await c.deactivate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // count 1, no release
    await c.deactivate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // count 0, release
    let expected: [FakeLoopbackProvisioner.Call] = [
        .init(ip: "127.0.10.1", hosts: hosts, active: true),
        .init(ip: "127.0.10.1", hosts: hosts, active: false),
    ]
    #expect(fake.calls == expected)
}

@Test func deactivateBelowZeroDoesNotDoubleRelease() async throws {
    let fake = FakeLoopbackProvisioner()
    let c = LoopbackCoordinator(provisioner: fake)
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)
    await c.deactivate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // -> 0, release
    await c.deactivate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // already 0, no-op
    let releases = fake.calls.filter { !$0.active }
    #expect(releases.count == 1)
}

@Test func failedActivateDoesNotIncrementCount() async throws {
    let fake = FakeLoopbackProvisioner()
    fake.setFailNext(true)
    let c = LoopbackCoordinator(provisioner: fake)
    await #expect(throws: ProvisionError.self) {
        try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)
    }
    // A subsequent successful activate is treated as the first (0 -> 1) again.
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)
    #expect(fake.calls.filter { $0.active }.count == 2)  // failed attempt + real first
    #expect(fake.calls.last == .init(ip: "127.0.10.1", hosts: hosts, active: true))
}

@Test func branchesAreIndependent() async throws {
    let fake = FakeLoopbackProvisioner()
    let c = LoopbackCoordinator(provisioner: fake)
    try await c.activate(branch: "a", ip: "127.0.10.1", hosts: hosts)
    try await c.activate(branch: "b", ip: "127.0.10.2", hosts: hosts)
    #expect(fake.calls.filter { $0.active }.count == 2)
}
