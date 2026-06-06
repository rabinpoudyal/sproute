import Testing

@testable import SproutEngine

@Suite struct LoopbackSweepTests {
    @Test func sweepDeactivatesOnlyStaleIPs() async {
        let fake = FakeLoopbackProvisioner()
        fake.setManaged(["127.0.10.1", "127.0.10.2", "127.0.10.3"])
        let coord = LoopbackCoordinator(provisioner: fake)

        await coord.sweep(live: ["127.0.10.2"])

        let expected: [FakeLoopbackProvisioner.Call] = [
            .init(ip: "127.0.10.1", hosts: [], active: false),
            .init(ip: "127.0.10.3", hosts: [], active: false),
        ]
        #expect(fake.calls == expected)
    }

    @Test func sweepWithNothingStaleDoesNothing() async {
        let fake = FakeLoopbackProvisioner()
        fake.setManaged(["127.0.10.5"])
        let coord = LoopbackCoordinator(provisioner: fake)

        await coord.sweep(live: ["127.0.10.5"])

        #expect(fake.calls.isEmpty)
    }

    @Test func sweepEmptyLiveClearsEverything() async {
        let fake = FakeLoopbackProvisioner()
        fake.setManaged(["127.0.10.8", "127.0.10.9"])
        let coord = LoopbackCoordinator(provisioner: fake)

        await coord.sweep(live: [])

        let expected: [FakeLoopbackProvisioner.Call] = [
            .init(ip: "127.0.10.8", hosts: [], active: false),
            .init(ip: "127.0.10.9", hosts: [], active: false),
        ]
        #expect(fake.calls == expected)
    }
}
